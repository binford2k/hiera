require 'hiera/util'
require 'hiera/interpolate'

begin
  require 'deep_merge'
rescue LoadError
end

class Hiera
  module Backend
    class Backend1xWrapper
      def initialize(wrapped)
        @wrapped = wrapped
      end

      def lookup(key, scope, order_override, resolution_type, context)
        Hiera.debug("Using Hiera 1.x backend API to access instance of class #{@wrapped.class.name}. Lookup recursion will not be detected")
        @wrapped.lookup(key, scope, order_override, resolution_type)
      end
    end

    class << self
      # Data lives in /var/lib/hiera by default.  If a backend
      # supplies a datadir in the config it will be used and
      # subject to variable expansion based on scope
      def datadir(backend, scope)
        backend = backend.to_sym

        if Config[backend] && Config[backend][:datadir]
          dir = Config[backend][:datadir]
        else
          dir = Hiera::Util.var_dir
        end

        if !dir.is_a?(String)
          raise(Hiera::InvalidConfigurationError,
                "datadir for #{backend} cannot be an array")
        end

        parse_string(dir, scope)
      end

      # Finds the path to a datafile based on the Backend#datadir
      # and extension
      #
      # If the file is not found nil is returned
      def datafile(backend, scope, source, extension)
        datafile_in(datadir(backend, scope), source, extension)
      end

      # @api private
      def datafile_in(datadir, source, extension)
        file = File.join(datadir, "#{source}.#{extension}")

        if File.exist?(file)
          file
        else
          Hiera.debug("Cannot find datafile #{file}, skipping")
          nil
        end
      end

      # Constructs a list of data sources to search
      #
      # If you give it a specific hierarchy it will just use that
      # else it will use the global configured one, failing that
      # it will just look in the 'common' data source.
      #
      # An override can be supplied that will be pre-pended to the
      # hierarchy.
      #
      # The source names will be subject to variable expansion based
      # on scope
      def datasources(scope, override=nil, hierarchy=nil)
        if hierarchy
          hierarchy = [hierarchy]
        elsif Config.include?(:hierarchy)
          hierarchy = [Config[:hierarchy]].flatten
        else
          hierarchy = ["common"]
        end

        hierarchy.insert(0, override) if override

        hierarchy.flatten.map do |source|
          source = parse_string(source, scope, {}, :order_override => override)
          yield(source) unless source == "" or source =~ /(^\/|\/\/|\/$)/
        end
      end

      # Constructs a list of data files to search
      #
      # If you give it a specific hierarchy it will just use that
      # else it will use the global configured one, failing that
      # it will just look in the 'common' data source.
      #
      # An override can be supplied that will be pre-pended to the
      # hierarchy.
      #
      # The source names will be subject to variable expansion based
      # on scope
      #
      # Only files that exist will be returned. If the file is missing, then
      # the block will not receive the file.
      #
      # @yield [String, String] the source string and the name of the resulting file
      # @api public
      def datasourcefiles(backend, scope, extension, override=nil, hierarchy=nil)
        datadir = Backend.datadir(backend, scope)
        Backend.datasources(scope, override, hierarchy) do |source|
          Hiera.debug("Looking for data source #{source}")
          file = datafile_in(datadir, source, extension)

          if file
            yield source, file
          end
        end
      end

      # Parse a string like <code>'%{foo}'</code> against a supplied
      # scope and additional scope.  If either scope or
      # extra_scope includes the variable 'foo', then it will
      # be replaced else an empty string will be placed.
      #
      # If both scope and extra_data has "foo", then the value in scope
      # will be used.
      #
      # @param data [String] The string to perform substitutions on.
      #   This will not be modified, instead a new string will be returned.
      # @param scope [#[]] The primary source of data for substitutions.
      # @param extra_data [#[]] The secondary source of data for substitutions.
      # @param context [#[]] Context can include :recurse_guard and :order_override.
      # @return [String] A copy of the data with all instances of <code>%{...}</code> replaced.
      #
      # @api public
      def parse_string(data, scope, extra_data={}, context={:recurse_guard => nil, :order_override => nil})
        Hiera::Interpolate.interpolate(data, scope, extra_data, context)
      end

      # Parses a answer received from data files
      #
      # Ultimately it just pass the data through parse_string but
      # it makes some effort to handle arrays of strings as well
      def parse_answer(data, scope, extra_data={}, context={:recurse_guard => nil, :order_override => nil})
        if data.is_a?(Numeric) or data.is_a?(TrueClass) or data.is_a?(FalseClass)
          return data
        elsif data.is_a?(String)
          return parse_string(data, scope, extra_data, context)
        elsif data.is_a?(Hash)
          answer = {}
          data.each_pair do |key, val|
            interpolated_key = parse_string(key, scope, extra_data, context)
            answer[interpolated_key] = parse_answer(val, scope, extra_data, context)
          end

          return answer
        elsif data.is_a?(Array)
          answer = []
          data.each do |item|
            answer << parse_answer(item, scope, extra_data, context)
          end

          return answer
        end
      end

      def resolve_answer(answer, resolution_type)
        case resolution_type
        when :array
          [answer].flatten.uniq.compact
        when :hash
          answer # Hash structure should be preserved
        else
          answer
        end
      end

      # Merges two hashes answers with the configured merge behavior.
      #         :merge_behavior: {:native|:deep|:deeper}
      #
      # Deep merge options use the Hash utility function provided by [deep_merge](https://github.com/peritor/deep_merge)
      #
      #  :native => Native Hash.merge
      #  :deep   => Use Hash.deep_merge
      #  :deeper => Use Hash.deep_merge!
      #
      def merge_answer(left,right)
        case Config[:merge_behavior]
        when :deeper,'deeper'
          left.deep_merge!(right, Config[:deep_merge_options] || {})
        when :deep,'deep'
          left.deep_merge(right, Config[:deep_merge_options] || {})
        else # Native and undefined
          left.merge(right)
        end
      end

      # Calls out to all configured backends in the order they
      # were specified.  The first one to answer will win.
      #
      # This lets you declare multiple backends, a possible
      # use case might be in Puppet where a Puppet module declares
      # default data using in-module data while users can override
      # using JSON/YAML etc.  By layering the backends and putting
      # the Puppet one last you can override module author data
      # easily.
      #
      # Backend instances are cached so if you need to connect to any
      # databases then do so in your constructor, future calls to your
      # backend will not create new instances

      # @param key [String] The key to lookup
      # @param scope [#[]] The primary source of data for substitutions.
      # @param order_override [String] An override that will be pre-pended to the hierarchy definition. Can be nil
      # @param resolution_type [Symbol] One of :hash, :array, or :priority. Can be nil which is the same as :priority
      # @param context [#[]] Context used for internal processing
      # @return [Object] The value that corresponds to the given key or nil if no such value cannot be found
      #
      def lookup(key, default, scope, order_override, resolution_type, context = {:recurse_guard => nil})
        @backends ||= {}
        answer = nil

        # order_override is kept as an explicit argument for backwards compatibility, but should be specified
        # in the context for internal handling.
        context ||= {}
        order_override ||= context[:order_override]
        context[:order_override] ||= order_override

        segments = key.split('.')
        subsegments = nil
        if segments.size > 1
          raise ArgumentError, "Resolution type :#{resolution_type} is illegal when doing segmented key lookups" unless resolution_type.nil? || resolution_type == :priority
          subsegments = segments.drop(1)
        end

        Config[:backends].each do |backend|
          backend_constant = "#{backend.capitalize}_backend"
          if constants.include?(backend_constant) || constants.include?(backend_constant.to_sym)
            backend = (@backends[backend] ||= find_backend(backend_constant))
            new_answer = backend.lookup(segments[0], scope, order_override, resolution_type, context)
            new_answer = qualified_lookup(subsegments, new_answer) unless subsegments.nil?

            next if new_answer.nil?

            case resolution_type
            when :array
              raise Exception, "Hiera type mismatch for key '#{key}': expected Array and got #{new_answer.class}" unless new_answer.kind_of? Array or new_answer.kind_of? String
              answer ||= []
              answer << new_answer
            when :hash
              raise Exception, "Hiera type mismatch for key '#{key}': expected Hash and got #{new_answer.class}" unless new_answer.kind_of? Hash
              answer ||= {}
              answer = merge_answer(new_answer,answer)
            else
              answer = new_answer
              break
            end
          end
        end

        answer = resolve_answer(answer, resolution_type) unless answer.nil?
        answer = parse_string(default, scope, {}, context) if answer.nil? and default.is_a?(String)

        return default if answer.nil?
        return answer
      end

      # Return a string describing where Hiera would be retrieving data, given
      # the current scope and configuration.
      def explain(scope)
        str = "Backend data directories:\n"
        Config[:backends].each do |backend|
          str << "  * #{backend}: #{Backend.datadir(backend, scope)}\n"
        end

        str << "\nExpanded hierarchy:\n"
        Backend.datasources(scope) do |datasource|
          str << "  * #{datasource}\n"
        end

        str << "\nFile lookup order:\n"
        Config[:backends].each do |backend|
          datadir = Backend.datadir(backend, scope)
          next unless datadir

          Backend.datasources(scope) do |source|
            path = File.join(datadir, "#{source}.#{backend}")
            str << "  * #{path}\n"
          end
        end

        str
      end

      def clear!
        @backends = {}
      end

      def qualified_lookup(segments, hash)
        value = hash
        segments.each do |segment|
          break if value.nil?
          if segment =~ /^[0-9]+$/
            segment = segment.to_i
            raise Exception, "Hiera type mismatch: Got #{value.class.name} when Array was expected enable lookup using key '#{segment}'" unless value.instance_of?(Array)
          else
            raise Exception, "Hiera type mismatch: Got #{value.class.name} when a non Array object that responds to '[]' was expected to enable lookup using key '#{segment}'" unless value.respond_to?(:'[]') && !value.instance_of?(Array);
          end
          value = value[segment]
        end
        value
      end

      def find_backend(backend_constant)
        backend = Backend.const_get(backend_constant).new
        return backend.method(:lookup).arity == 4 ? Backend1xWrapper.new(backend) : backend
      end
      private :find_backend
    end
  end
end
