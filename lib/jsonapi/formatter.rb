module JSONAPI
  class Formatter
    def format(arg)
      arg.to_s
    end

    def unformat(arg)
      arg
    end

    def cached
      return FormatterWrapperCache.new(self)
    end

    def self.formatter_for(format)
      "#{format.to_s.camelize}Formatter".safe_constantize.new
    end
  end

  class KeyFormatter < Formatter
    def format(key)
      super
    end

    def unformat(formatted_key)
      super
    end
  end

  class RouteFormatter < Formatter
    def format(route)
      super
    end

    def unformat(formatted_route)
      super
    end
  end

  class ValueFormatter < Formatter
    def format(raw_value)
      super(raw_value)
    end

    def unformat(value)
      super(value)
    end

    def self.value_formatter_for(type)
      "#{type.to_s.camelize}ValueFormatter".safe_constantize.new
    end
  end

  # Warning: Not thread-safe. Wrap in ThreadLocalVar as needed.
  class FormatterWrapperCache
    attr_reader :formatter

    def initialize(formatter)
      @formatter = formatter
      @format_cache = NaiveCache.new{|arg| formatter.format(arg) }
      @unformat_cache = NaiveCache.new{|arg| formatter.unformat(arg) }
    end

    def format(arg)
      @format_cache.get(arg)
    end

    def unformat(arg)
      @unformat_cache.get(arg)
    end

    def cached
      self
    end

    delegate :is_a?, :kind_of?, :instance_of?, to: :formatter
  end
end

class UnderscoredKeyFormatter < JSONAPI::KeyFormatter
end

class CamelizedKeyFormatter < JSONAPI::KeyFormatter
  def format(key)
    key.to_s.camelize(:lower)
  end

  def unformat(formatted_key)
    formatted_key.to_s.underscore
  end
end

class DasherizedKeyFormatter < JSONAPI::KeyFormatter
  def format(key)
    key.to_s.underscore.dasherize
  end

  def unformat(formatted_key)
    formatted_key.to_s.underscore
  end
end

class DefaultValueFormatter < JSONAPI::ValueFormatter
  def format(raw_value)
    raw_value
  end
end

class IdValueFormatter < JSONAPI::ValueFormatter
  def format(raw_value)
    return if raw_value.nil?
    raw_value.to_s
  end
end

class UnderscoredRouteFormatter < JSONAPI::RouteFormatter
end

class CamelizedRouteFormatter < JSONAPI::RouteFormatter
  def format(route)
    route.to_s.camelize(:lower)
  end

  def unformat(formatted_route)
    formatted_route.to_s.underscore
  end
end

class DasherizedRouteFormatter < JSONAPI::RouteFormatter
  def format(route)
    route.to_s.dasherize
  end

  def unformat(formatted_route)
    formatted_route.to_s.underscore
  end
end
