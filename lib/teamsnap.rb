require "faraday"
require "typhoeus"
require "typhoeus/adapters/faraday"
require "oj"
require "inflecto"
require "virtus"
require "date"
require "securerandom"

require_relative "teamsnap/version"

Oj.default_options = {
  :mode => :compat,
  :symbol_keys => true,
  :class_cache => true
}

Faraday::Request.register_middleware(
  :teamsnap_auth_middleware => -> { TeamSnap::AuthMiddleware }
)

Inflecto.inflections do |inflect|
  inflect.irregular "member_preferences", "member_preferences"
  inflect.irregular "member_preferences", "members_preferences"
  inflect.irregular "opponent_results", "opponent_results"
  inflect.irregular "opponent_results", "opponents_results"
  inflect.irregular "team_preferences", "team_preferences"
  inflect.irregular "team_preferences", "teams_preferences"
  inflect.irregular "team_results", "team_results"
  inflect.irregular "team_results", "teams_results"
end

module TeamSnap
  EXCLUDED_RELS = %w(me apiv2_root root self dude sweet random xyzzy)
  DEFAULT_URL = "http://apiv3.teamsnap.com"
  Error = Class.new(StandardError)
  NotFound = Class.new(TeamSnap::Error)

  class AuthMiddleware < Faraday::Middleware
    def initialize(app, options)
      @options = options
      super(app)
    end

    def call(env)
      token = @options[:token]
      client_id = @options[:client_id]
      client_secret = @options[:client_secret]

      if token
        env[:request_headers].merge!({"Authorization" => "Bearer #{token}"})
      elsif client_id && client_secret
        query_params = Hash[URI.decode_www_form(env.url.query || "")]
          .merge({
            hmac_client_id: client_id,
            hmac_nonce: SecureRandom.uuid,
            hmac_timestamp: Time.now.to_i
          })
        env.url.query = URI.encode_www_form(query_params)

        body = if env.body.is_a?(Hash)
                 Faraday::Utils::ParamsHash.new.merge(env.body).to_query
               else
                 env.body
               end
        message = "/?" + env.url.query.to_s + (body || "")
        digest = OpenSSL::Digest.new("sha256")
        message_hash = digest.hexdigest(message)

        env.request_headers["X-Teamsnap-Hmac"] = OpenSSL::HMAC.hexdigest(
          digest, client_secret, message_hash
        )
      end

      @app.call(env)
    end
  end

  class << self
    def collection(href, resp)
      Module.new do
        define_singleton_method(:included) do |descendant|
          descendant.send(:include, TeamSnap::Item)
          descendant.extend(TeamSnap::Collection)
          descendant.instance_variable_set(:@href, href)
          descendant.instance_variable_set(:@resp, resp)
        end
      end
    end

    def hashify(arr)
      arr.to_h
    rescue NoMethodError
      arr.inject({}) { |hash, (key, value)| hash[key] = value; hash }
    end

    def init(opts = {})
      opts[:url] ||= DEFAULT_URL
      unless opts.include?(:token) || (
        opts.include?(:client_id) && opts.include?(:client_secret)
      )
        raise ArgumentError.new(
          "You must provide a :token or :client_id and :client_secret pair to '.init'"
        )
      end

      opts[:backup_cache] = opts.fetch(:backup_cache) { true }
      if opts[:backup_cache]
        opts[:backup_cache_file] = TeamSnap.backup_file_for(opts[:backup_cache])
      end

      self.client = Faraday.new(
        :url => opts.fetch(:url),
        :parallel_manager => Typhoeus::Hydra.new
      ) do |c|
        c.request :teamsnap_auth_middleware, {
          :token => opts[:token],
          :client_id => opts[:client_id],
          :client_secret => opts[:client_secret]
        }
        c.adapter :typhoeus
      end

      collection = TeamSnap.run(:get, "/", {}, opts)

      classes = []
      client.in_parallel do
        classes = collection
          .fetch(:links)
          .map { |link| classify_rel(link) }
          .compact
      end

      classes.each { |cls| cls.parse_collection }

      apply_endpoints(self, collection) && true
    end

    def run(via, href, args = {}, opts = {})
      resp = client.send(via, href, args)

      if resp.status == 200
        collection = Oj.load(resp.body).fetch(:collection)
        TeamSnap.write_backup_file(opts[:backup_cache_file], collection)
        collection
      else
        if TeamSnap.backup_file_exists?(opts[:backup_cache_file])
          warn("Connection to API failed.. using backup cache file to initialize endpoints")
          Oj.load(IO.read(opts[:backup_cache_file]))
        else
          error_message = parse_error(resp)
          raise TeamSnap::Error.new(error_message)
        end
      end
    end

    def backup_file_for(backup_cache)
      backup_cache == true ? "./tmp/.teamsnap_rb" : backup_cache
    end

    def write_backup_file(file_location, collection)
      return unless file_location
      dir_location = File.dirname(file_location)
      if Dir.exist?(dir_location)
        File.open(file_location, "w+") { |f| f.write Oj.dump(collection) }
      else
        warn(
          "WARNING: Directory '#{dir_location}' does not exist. " +
          "Backup cache functionality will not work until this is resolved."
        )
      end
    end

    def backup_file_exists?(backup_cache_file)
      !!backup_cache_file && File.exist?(backup_cache_file)
    end

    def parse_error(resp)
      Oj.load(resp.body)
        .fetch(:collection)
        .fetch(:error)
        .fetch(:message)
    end

    def load_items(collection)
      collection
        .fetch(:items) { [] }
        .map { |item|
          data = parse_data(item).merge(:href => item[:href])
          type = type_of(item)
          cls = load_class(type, data)

          cls.new(data).tap { |obj|
            obj.send(:load_links, item.fetch(:links) { [] })
          }
        }
    end

    def apply_endpoints(obj, collection)
      collection
        .fetch(:queries) { [] }
        .each { |endpoint| register_endpoint(obj, endpoint, :via => :get) }

      collection
        .fetch(:commands) { [] }
        .each { |endpoint| register_endpoint(obj, endpoint, :via => :post) }
    end

    private

    attr_accessor :client

    def classify_rel(link)
      return if EXCLUDED_RELS.include?(link.fetch(:rel))

      rel = link.fetch(:rel)
      href = link.fetch(:href)
      name = Inflecto.classify(rel)
      resp = client.get(href)

      TeamSnap.const_set(
        name, Class.new { include TeamSnap.collection(href, resp) }
      ) unless TeamSnap.const_defined?(name, false)
    end

    def register_endpoint(obj, endpoint, opts)
      rel = endpoint.fetch(:rel)
      href = endpoint.fetch(:href)
      valid_args = endpoint.fetch(:data) { [] }
        .map { |datum| datum.fetch(:name).to_sym }
      via = opts.fetch(:via)

      obj.define_singleton_method(rel) do |*args|
        args = Hash[*args]

        unless args.all? { |arg, _| valid_args.include?(arg) }
          raise ArgumentError.new(
            "Invalid argument(s). Valid argument(s) are #{valid_args.inspect}"
          )
        end

        TeamSnap.load_items(
          TeamSnap.run(via, href, args)
        )
      end
    end

    def parse_data(item)
      data = item
        .fetch(:data)
        .map { |datum|
          name = datum.fetch(:name)
          value = datum.fetch(:value)
          type = datum.fetch(:type) { :default }

          value = DateTime.parse(value) if value && type == "DateTime"

          [name, value]
        }
      TeamSnap.hashify(data)
    end

    def type_of(item)
      item
        .fetch(:data)
        .find { |datum| datum.fetch(:name) == "type" }
        .fetch(:value)
    end

    def load_class(type, data)
      TeamSnap.const_get(Inflecto.camelize(type), false).tap { |cls|
        unless cls.include?(Virtus::Model::Core)
          cls.class_eval do
            include Virtus.value_object

            values do
              attribute :href, String
              data.each { |name, value| attribute name, value.class }
            end
          end
        end
      }
    end
  end

  module Item
    private

    def load_links(links)
      links.each do |link|
        next if EXCLUDED_RELS.include?(link.fetch(:rel))

        rel = link.fetch(:rel)
        href = link.fetch(:href)
        is_singular = rel == Inflecto.singularize(rel)

        define_singleton_method(rel) {
          instance_variable_get("@#{rel}") || instance_variable_set(
            "@#{rel}", -> {
              coll = TeamSnap.load_items(
                TeamSnap.run(:get, href)
              )
              is_singular ? coll.first : coll
            }.call
          )
        }
      end
    end
  end

  module Collection
    def href
      self.instance_variable_get(:@href)
    end

    def resp
      self.instance_variable_get(:@resp)
    end

    def parse_collection
      if resp.status == 200
        collection = Oj.load(resp.body)
          .fetch(:collection)

        TeamSnap.apply_endpoints(self, collection)
        enable_find if respond_to?(:search)
      else
        error_message = TeamSnap.parse_error(resp)
        raise TeamSnap::Error.new(error_message)
      end
    end

    private

    def enable_find
      define_singleton_method(:find) do |id|
        search(:id => id).first.tap do |object|
          raise TeamSnap::NotFound.new(
            "Could not find a #{self} with an id of '#{id}'."
          ) unless object
        end
      end
    end
  end
end
