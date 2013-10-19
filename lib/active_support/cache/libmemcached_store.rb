require 'memcached'
require 'digest/sha1'

class Memcached
  # The latest version of memcached (0.11) doesn't support hostnames with dashes
  # in their names, so we overwrite it here to be more lenient.
  def set_servers(servers)
    [*servers].each_with_index do |server, index|
      host, port = server.split(":")
      Lib.memcached_server_add(@struct, host, port.to_i)
    end
  end
end

module ActiveSupport
  module Cache
    class LibmemcachedStore < Store
      class FetchWithRaceConditionTTLEntry
        attr_accessor :value, :extended

        def initialize(value, expires_in)
          @value, @extended = value, false
          @expires_at = Time.now.to_i + expires_in
        end

        def expires_in
          [@expires_at - Time.now.to_i, 1].max # never set to 0 -> never expires
        end

        def expired?
          @expires_at <= Time.now.to_i
        end
      end

      attr_reader :addresses

      ESCAPE_KEY_CHARS = /[\x00-\x20%\x7F-\xFF]/n

      DEFAULT_OPTIONS = {
        :distribution => :consistent,
        :no_block => true
      }

      def initialize(*addresses)
        addresses.flatten!
        options = addresses.extract_options!
        addresses = %w(localhost) if addresses.empty?

        if options[:prefix_key]
          @namespace_length = options[:prefix_key].length
          @namespace_length += options[:prefix_delimiter].length if options[:prefix_delimiter]
        else
          @namespace_length = 0
        end

        @addresses = addresses
        @cache = Memcached.new(@addresses, options.reverse_merge(DEFAULT_OPTIONS))
        extend ActiveSupport::Cache::Strategy::LocalCache
      end

      def fetch(key, options={}, &block)
        if options && options[:race_condition_ttl]
          fetch_with_race_condition_ttl(key, options, &block)
        else
          super
        end
      end

      def fetch_with_race_condition_ttl(key, options={}, &block)
        options = options.dup

        race_ttl = options.delete(:race_condition_ttl) || raise("Use :race_condition_ttl option or normal fetch")
        expires_in = options.fetch(:expires_in)
        options[:expires_in] = expires_in + race_ttl
        options[:preserve_race_condition_entry] = true

        value = fetch(key, options) { FetchWithRaceConditionTTLEntry.new(yield, expires_in) }

        return value unless value.is_a?(FetchWithRaceConditionTTLEntry)

        if value.expired? && !value.extended
          # we take care of refreshing the cache, all others should keep reading
          value.extended = true
          write(key, value, options.merge(:expires_in => value.expires_in + race_ttl))

          # calculate new value and store it
          value = FetchWithRaceConditionTTLEntry.new(yield, expires_in)
          write(key, value, options)
        end

        value.value
      end

      def read(key, options = nil)
        key = expanded_key(key)
        super
        value = @cache.get(escape_and_normalize(key), marshal?(options))
        convert_race_condition_entry(value, options)
      rescue Memcached::NotFound
        nil
      rescue Memcached::Error => e
        log_error(e)
        nil
      end

      def read_multi(*names)
        names.flatten!
        options = names.extract_options!

        return {} if names.empty?

        mapping = Hash[names.map {|name| [escape_and_normalize(expanded_key(name)), name] }]
        raw_values = @cache.get(mapping.keys, marshal?(options))

        values = {}
        raw_values.each do |key, value|
          values[mapping[key]] = value
        end
        values
      rescue Memcached::Error => e
        log_error(e)
        {}
      end

      # Set the key to the given value. Pass :unless_exist => true if you want to
      # skip setting a key that already exists.
      def write(key, value, options = nil)
        key = expanded_key(key)
        super
        method = (options && options[:unless_exist]) ? :add : :set
        @cache.send(method, escape_and_normalize(key), value, expires_in(options), marshal?(options))
        true
      rescue Memcached::Error => e
        log_error(e)
        false
      end

      def delete(key, options = nil)
        key = expanded_key(key)
        super
        @cache.delete(escape_and_normalize(key))
        true
      rescue Memcached::NotFound
        nil
      rescue Memcached::Error => e
        log_error(e)
        false
      end

      def exist?(key, options = nil)
        key = expanded_key(key)
        !read(key, options).nil?
      end

      def increment(key, amount=1)
        key = expanded_key(key)
        log 'incrementing', key, amount
        @cache.incr(escape_and_normalize(key), amount)
      rescue Memcached::Error
        nil
      end

      def decrement(key, amount=1)
        key = expanded_key(key)
        log 'decrementing', key, amount
        @cache.decr(escape_and_normalize(key), amount)
      rescue Memcached::Error
        nil
      end

      def delete_matched(matcher, options = nil)
        super
        raise NotImplementedError
      end

      # Flushes all data in memory
      def clear
        @cache.flush
      end

      def stats
        @cache.stats
      end

      # Resets server connections, forcing a reconnect. This is required in
      # cases where processes fork, but continue sharing the same memcached
      # connection. You want to call this after the fork to make sure the
      # new process has its own connection.
      def reset
        @cache.reset
      end

      private

        def convert_race_condition_entry(value, options)
          if (!options || !options[:preserve_race_condition_entry]) && value.is_a?(FetchWithRaceConditionTTLEntry)
            value.value
          else
            value
          end
        end

        def escape_and_normalize(key)
          key = key.to_s.dup.force_encoding("BINARY").gsub(ESCAPE_KEY_CHARS) { |match| "%#{match.getbyte(0).to_s(16).upcase}" }
          key_length = key.length

          return key if @namespace_length + key_length <= 250

          max_key_length = 213 - @namespace_length
          "#{key[0, max_key_length]}:md5:#{Digest::MD5.hexdigest(key)}"
        end

        def expanded_key(key) # :nodoc:
          return key.cache_key.to_s if key.respond_to?(:cache_key)

          case key
          when Array
            if key.size > 1
              key = key.collect { |element| expanded_key(element) }
            else
              key = key.first
            end
          when Hash
            key = key.sort_by { |k,_| k.to_s }.collect { |k, v| "#{k}=#{v}" }
          end

          key.to_param
        end

        def expires_in(options)
          (options || {})[:expires_in] || 0
        end

        def marshal?(options)
          !(options || {})[:raw]
        end

        def log_error(exception)
          logger.error "MemcachedError (#{exception.inspect}): #{exception.message}" if logger && !@logger_off
        end
    end
  end
end
