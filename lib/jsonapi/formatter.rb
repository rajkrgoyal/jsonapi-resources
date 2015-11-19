module JSONAPI
  class Formatter
    class << self
      def format(arg)
        arg.to_s
      end

      def unformat(arg)
        arg
      end

      def formatter_for(format)
        formatter_class_name = "#{format.to_s.camelize}Formatter"
        formatter_class_name.constantize
      end
    end
  end

  class KeyFormatter < Formatter
    class << self
      def format(key)
        super
      end

      def unformat(formatted_key)
        super
      end
    end
  end

  class TypeFormatter < Formatter
    class << self
      def format(type_key)
        super
      end

      def unformat(formatted_type_key)
        super
      end
    end
  end

  class RouteFormatter < Formatter
    class << self
      def format(route)
        super
      end

      def unformat(formatted_route)
        super
      end
    end
  end

  class ValueFormatter < Formatter
    class << self
      def format(raw_value)
        super(raw_value)
      end

      def unformat(value)
        super(value)
      end

      def value_formatter_for(type)
        formatter_name = "#{type.to_s.camelize}Value"
        formatter_for(formatter_name)
      end
    end
  end
end

class UnderscoredKeyFormatter < JSONAPI::KeyFormatter
  class << self
    def format(key)
      super.underscore
    end

    def unformat(key)
      super
    end
  end
end

class CamelizedKeyFormatter < JSONAPI::KeyFormatter
  class << self
    def format(key)
      super.camelize(:lower)
    end

    def unformat(formatted_key)
      formatted_key.to_s.underscore
    end
  end
end

class DasherizedKeyFormatter < JSONAPI::KeyFormatter
  class << self
    def format(key)
      super.underscore.dasherize
    end

    def unformat(formatted_key)
      formatted_key.to_s.underscore
    end
  end
end

class DefaultValueFormatter < JSONAPI::ValueFormatter
  class << self
    def format(raw_value)
      raw_value
    end
  end
end

class IdValueFormatter < JSONAPI::ValueFormatter
  class << self
    def format(raw_value)
      return if raw_value.nil?
      raw_value.to_s
    end
  end
end

class UnderscoredRouteFormatter < JSONAPI::RouteFormatter
end

class CamelizedRouteFormatter < JSONAPI::RouteFormatter
  class << self
    def format(route)
      super.camelize(:lower)
    end

    def unformat(formatted_route)
      formatted_route.to_s.underscore
    end
  end
end

class DasherizedRouteFormatter < JSONAPI::RouteFormatter
  class << self
    def format(route)
      super.dasherize
    end

    def unformat(formatted_route)
      formatted_route.to_s.underscore
    end
  end
end

class SingularTypeFormatter < JSONAPI::TypeFormatter
end

class PluralTypeFormatter < JSONAPI::TypeFormatter
  class << self
    def format(type_key)
      type_key.pluralize
    end

    def unformat(formatted_type_key)
      formatted_type_key.singularize
    end
  end
end

class ClassNameTypeFormatter < JSONAPI::TypeFormatter
  class << self
    def format(type_key)
      type_key.underscore.classify
    end

    def unformat(formatted_type_key)
      super
    end
  end
end
