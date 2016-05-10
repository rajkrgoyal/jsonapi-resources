module JSONAPI
  class IncludeDirectives
    # Construct an IncludeDirectives Hash from an array of dot separated include strings.
    # For example ['posts.comments.tags']
    # will transform into =>
    # {
    #   posts:{
    #     include:true,
    #     include_related:{
    #       comments:{
    #         include:true,
    #         include_related:{
    #           tags:{
    #             include:true
    #           }
    #         }
    #       }
    #     }
    #   }
    # }

    def initialize(includes_array)
      @include_directives_hash = { include_related: {} }
      includes_array.each do |include|
        parse_include(include)
      end
    end

    def include_directives
      @include_directives_hash
    end

    def model_includes
      get_includes(@include_directives_hash)
    end

    def paths
      delve_paths(model_includes)
    end

    private

    def get_related(current_path)
      current = @include_directives_hash
      current_path.split('.').each do |fragment|
        fragment = fragment.to_sym
        current[:include_related][fragment] ||= { include: false, include_related: {} }
        current = current[:include_related][fragment]
      end
      current
    end

    def get_includes(directive)
      directive[:include_related].map do |name, sub_directive|
        sub = get_includes(sub_directive)
        sub.any? ? { name => sub } : name
      end
    end

    def parse_include(include)
      parts = include.split('.')
      local_path = ''

      parts.each do |name|
        local_path += local_path.length > 0 ? ".#{name}" : name
        related = get_related(local_path)
        related[:include] = true
      end
    end

    def delve_paths(obj)
      case obj
        when Array
          obj.map{|elem| delve_paths(elem)}.flatten(1)
        when Hash
          obj.map{|k,v| [[k]] + delve_paths(v).map{|path| [k] + path } }.flatten(1)
        when Symbol, String
          [[obj]]
        else
          raise "delve_paths cannot descend into #{obj.class.name}"
      end
    end
  end
end
