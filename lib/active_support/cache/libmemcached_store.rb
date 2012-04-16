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
      attr_reader :addresses

      DEFAULT_OPTIONS = {
        :distribution => :consistent,
        :no_block => true,
        :failover => true
      }

      def initialize(*addresses)
        addresses.flatten!
        options = addresses.extract_options!
        addresses = %w(localhost) if addresses.empty?

        @addresses = addresses
        @cache = Memcached.new(@addresses, options.reverse_merge(DEFAULT_OPTIONS))
        extend ActiveSupport::Cache::Strategy::LocalCache
      end

      def valid_key(key)
        if key.is_a?(Array)
          key.map {|k| valid_key(k) }
        else
          if key && key.size > 250
            "#{Digest::SHA1.hexdigest(key)}-autofixed"
          else
            key
          end
        end
      end

      def read(key, options = nil)
        super
        @cache.get(valid_key(key), marshal?(options))
      rescue Memcached::NotFound
        nil
      rescue Memcached::Error => e
        log_error(e)
        nil
      end

      def read_multi(*keys)
        read(keys) || {}
      end

      # Set the key to the given value. Pass :unless_exist => true if you want to
      # skip setting a key that already exists.
      def write(key, value, options = nil)
        super
        method = (options && options[:unless_exist]) ? :add : :set
        @cache.send(method, valid_key(key), value, expires_in(options), marshal?(options))
        true
      rescue Memcached::Error => e
        log_error(e)
        false
      end

      def delete(key, options = nil)
        super
        @cache.delete(valid_key(key))
        true
      rescue Memcached::NotFound
        nil
      rescue Memcached::Error => e
        log_error(e)
        false
      end

      def exist?(key, options = nil)
        !read(key, options).nil?
      end

      def increment(key, amount=1)
        log 'incrementing', key, amount
        @cache.incr(valid_key(key), amount)
      rescue Memcached::Error
        nil
      end

      def decrement(key, amount=1)
        log 'decrementing', key, amount
        @cache.decr(valid_key(key), amount)
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
