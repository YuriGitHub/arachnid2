require "arachnid2/version"

require 'tempfile'
require "typhoeus"
require "bloomfilter-rb"
require "adomain"
require "addressable/uri"
require "nokogiri"

class Arachnid2

  # META:
  #   About the origins of this crawling approach
  # The Crawler is heavily borrowed from by Arachnid.
  # Original: https://github.com/dchuk/Arachnid
  # Other iterations I've borrowed liberally from:
  #   - https://github.com/matstc/Arachnid
  #   - https://github.com/intrigueio/Arachnid
  #   - https://github.com/jhulme/Arachnid
  # And this was originally written as a part of Tellurion's bot
  # https://github.com/samnissen/tellurion_bot

  MAX_CRAWL_TIME = 600
  BASE_CRAWL_TIME = 15
  MAX_URLS = 10000
  BASE_URLS = 50
  DEFAULT_LANGUAGE = "en-IE, en-UK;q=0.9, en-NL;q=0.8, en-MT;q=0.7, en-LU;q=0.6, en;q=0.5, *;0.4"
  DEFAULT_USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_13_4) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/11.1 Safari/605.1.15"

  NON_HTML_EXTENSIONS = {
    3 => ['.gz'],
    4 => ['.jpg', '.png', '.m4a', '.mp3', '.mp4', '.pdf', '.zip',
          '.wmv', '.gif', '.doc', '.xls', '.pps', '.ppt', '.tar',
          '.iso', '.dmg', '.bin', '.ics', '.exe', '.wav', '.mid'],
    5 => ['.xlsx', '.docx', '.pptx', '.tiff', '.zipx'],
    8 => ['.torrent']
  }
  MEMORY_USE_FILE = "/sys/fs/cgroup/memory/memory.usage_in_bytes"
  MEMORY_LIMIT_FILE = "/sys/fs/cgroup/memory/memory.limit_in_bytes"
  MAXIMUM_LOAD_RATE = 79.9

  #
  # Creates the object to execute the crawl
  #
  # @example
  #   url = "https://daringfireball.net"
  #   spider = Arachnid2.new(url)
  #
  # @param [String] url
  #
  # @return [Arachnid2] self
  #
  def initialize(url)
    @url = url
    @domain = Adomain[@url]
  end

  #
  # Visits a URL, gathering links and visiting them,
  # until running out of time, memory or attempts.
  #
  # @example
  #   url = "https://daringfireball.net"
  #   spider = Arachnid2.new(url)
  #
  #   opts = {
  #     :time_box => 30,
  #     :headers => {
  #       'Accept-Language' => "en-UK",
  #       'User-Agent' => "Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:47.0) Gecko/20100101 Firefox/47.0",
  #     },
  #     :proxy => {
  #       :ip => "1.2.3.4",
  #       :port => "1234",
  #       :username => "sam",
  #       :password => "coolcoolcool",
  #     }
  #   }
  #   responses = []
  #   spider.crawl(opts) { |response|
  #     responses << response
  #   }
  #
  # @param [Hash] opts
  #
  # @return nil
  #
  def crawl(opts = {})
    preflight(opts)

    until @global_queue.empty?
      @global_queue.size.times do
        begin
          q = @global_queue.shift

          break if @global_visited.size >= @crawl_options[:max_urls]
          break if Time.now > @crawl_options[:time_limit]
          break if memory_danger?

          @global_visited.insert(q)

          request = Typhoeus::Request.new(q, request_options)

          request.on_complete do |response|
            links = process(response)
            next unless links

            yield response

            vacuum(links, response)
          end

          request.run
        ensure
          @cookie_file.close! if @cookie_file
        end
      end
    end
  end

  private
    def process(response)
      return false unless Adomain["#{response.effective_url}"].include? @domain

      elements = Nokogiri::HTML.parse(response.body).css('a')
      return elements.map {|link| link.attribute('href').to_s}.uniq.sort.delete_if {|href| href.empty? }
    end

    def vacuum(links, response)
      links.each do |link|
        next if link.match(/^\(|^javascript:|^mailto:|^#|^\s*$|^about:/)

        begin
          absolute_link = make_absolute(link, response.effective_url)

          next if skip_link?(absolute_link)

          @global_queue << absolute_link
        rescue Addressable::URI::InvalidURIError
        end
      end
    end

    def skip_link?(absolute_link)
      internal  = internal_link?(absolute_link)
      visited   = @global_visited.include?(absolute_link)
      ignored   = extension_ignored?(absolute_link)
      known     = @global_queue.include?(absolute_link)

      !internal || visited || ignored || known
    end

    def preflight(opts)
      @options = opts
      @crawl_options = crawl_options
      # TODO: write looping to take advantage of Hydra
      # @hydra = Typhoeus::Hydra.new(:max_concurrency => 1)
      @global_visited = BloomFilter::Native.new(:size => 1000000, :hashes => 5, :seed => 1, :bucket => 8, :raise => true)
      @global_queue = [@url]
    end

    def bound_time
      boundary = "#{@options[:time_box]}".to_i
      boundary = BASE_CRAWL_TIME if boundary <= 0
      boundary = MAX_CRAWL_TIME  if boundary >  MAX_CRAWL_TIME

      return Time.now + boundary
    end

    def bound_urls
      amount = "#{@options[:max_urls]}".to_i
      amount = BASE_URLS if amount <= 0
      amount = MAX_URLS  if amount >  MAX_URLS

      amount
    end

    def request_options
      @cookie_file ||= Tempfile.new('cookies')

      @request_options = {
        timeout: 10000,
        followlocation: true,
        cookiefile: @cookie_file.path,
        cookiejar: @cookie_file.path,
        headers: @options[:headers]
      }

      @request_options[:headers] ||= {}
      @request_options[:headers]['Accept-Language'] ||= DEFAULT_LANGUAGE
      @request_options[:headers]['User-Agent']      ||= DEFAULT_USER_AGENT

      @request_options
    end

    def crawl_options
      @crawl_options ||= nil

      if !@crawl_options
        @crawl_options = { :max_urls => max_urls, :time_limit => time_limit }

        @crawl_options[:proxy] = "#{@options[:proxy][:ip]}:#{@options[:proxy][:port]}" if @options.dig(:proxy, :ip)
        @crawl_options[:proxyuserpwd] = "#{@options[:proxy][:username]}:#{@options[:proxy][:password]}" if @options.dig(:proxy, :username)
      end

      @crawl_options
    end

    def max_urls
      bound_urls
    end

    def time_limit
      bound_time
    end

    def make_absolute(href, root)
      Addressable::URI.parse(root).join(Addressable::URI.parse(href)).to_s
    end

    def internal_link?(absolute_url)
      "#{Adomain[absolute_url]}".include? @domain
    end

    def extension_ignored?(url)
      return false if url.empty?

      !NON_HTML_EXTENSIONS.values.flatten.find { |e| url.downcase.end_with? e.downcase }.nil?
    end

    def memory_danger?
      return false unless in_docker?

      use      = "#{File.open(MEMORY_USE_FILE, "rb").read}".to_f
      @limit ||= "#{File.open(MEMORY_LIMIT_FILE, "rb").read}".to_f

      return false unless ( (use > 0.0) && (@limit > 0.0) )

      return ( ( (use / @limit) * 100.0 ) >= MAXIMUM_LOAD_RATE )
    end

    def in_docker?
      return false unless File.file?(MEMORY_USE_FILE)
      true
    end

end
