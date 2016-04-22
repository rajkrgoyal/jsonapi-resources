require 'jsonapi/formatter'
require 'jsonapi/operations_processor'
require 'jsonapi/active_record_operations_processor'
require 'concurrent'

module JSONAPI
  class Configuration
    attr_reader :json_key_format,
                :resource_key_type,
                :route_format,
                :raise_if_parameters_not_allowed,
                :operations_processor,
                :allow_include,
                :allow_sort,
                :allow_filter,
                :default_paginator,
                :default_page_size,
                :maximum_page_size,
                :use_text_errors,
                :top_level_links_include_pagination,
                :top_level_meta_include_record_count,
                :top_level_meta_record_count_key,
                :exception_class_whitelist,
                :always_include_to_one_linkage_data,
                :always_include_to_many_linkage_data,
                :cache_formatters

    def initialize
      #:underscored_key, :camelized_key, :dasherized_key, or custom
      self.json_key_format = :dasherized_key

      #:underscored_route, :camelized_route, :dasherized_route, or custom
      self.route_format = :dasherized_route

      #:basic, :active_record, or custom
      self.operations_processor = :active_record

      #:integer, :uuid, :string, or custom (provide a proc)
      self.resource_key_type = :integer

      # optional request features
      self.allow_include = true
      self.allow_sort = true
      self.allow_filter = true

      self.raise_if_parameters_not_allowed = true

      # :none, :offset, :paged, or a custom paginator name
      self.default_paginator = :none

      # Output pagination links at top level
      self.top_level_links_include_pagination = true

      self.default_page_size = 10
      self.maximum_page_size = 20

      # Metadata
      # Output record count in top level meta for find operation
      self.top_level_meta_include_record_count = false
      self.top_level_meta_record_count_key = :record_count

      self.use_text_errors = false

      # List of classes that should not be rescued by the operations processor.
      # For example, if you use Pundit for authorization, you might
      # raise a Pundit::NotAuthorizedError at some point during operations
      # processing. If you want to use Rails' `rescue_from` macro to
      # catch this error and render a 403 status code, you should add
      # the `Pundit::NotAuthorizedError` to the `exception_class_whitelist`.
      self.exception_class_whitelist = []

      # Resource Linkage
      # Controls the serialization of resource linkage for non compound documents
      # NOTE: always_include_to_many_linkage_data is not currently implemented
      self.always_include_to_one_linkage_data = false
      self.always_include_to_many_linkage_data = false

      # Formatter Caching
      # Set to false to disable caching of string operations on keys and links.
      self.cache_formatters = true
    end

    def cache_formatters=(bool)
      @cache_formatters = bool
      if bool
        @key_formatter_tlv = Concurrent::ThreadLocalVar.new
        @route_formatter_tlv = Concurrent::ThreadLocalVar.new
      else
        @key_formatter_tlv = nil
        @route_formatter_tlv = nil
      end
    end

    def json_key_format=(format)
      @json_key_format = format
      if @cache_formatters
        @key_formatter_tlv = Concurrent::ThreadLocalVar.new
      end
    end

    def route_format=(format)
      @route_format = format
      if @cache_formatters
        @route_formatter_tlv = Concurrent::ThreadLocalVar.new
      end
    end

    def key_formatter
      if self.cache_formatters
        formatter = @key_formatter_tlv.value
        return formatter if formatter
      end

      formatter = JSONAPI::Formatter.formatter_for(self.json_key_format)

      if self.cache_formatters
        formatter = @key_formatter_tlv.value = formatter.cached
      end

      return formatter
    end

    def resource_key_type=(key_type)
      @resource_key_type = key_type
    end

    def route_formatter
      if self.cache_formatters
        formatter = @route_formatter_tlv.value
        return formatter if formatter
      end

      formatter = JSONAPI::Formatter.formatter_for(self.route_format)

      if self.cache_formatters
        formatter = @route_formatter_tlv.value = formatter.cached
      end

      return formatter
    end

    def operations_processor=(operations_processor)
      @operations_processor_name = operations_processor
      @operations_processor = JSONAPI::OperationsProcessor.operations_processor_for(@operations_processor_name)
    end

    def exception_class_whitelisted?(e)
      @exception_class_whitelist.flatten.any? { |k| e.class.ancestors.include?(k) }
    end

    attr_writer :allow_include, :allow_sort, :allow_filter

    attr_writer :default_paginator

    attr_writer :default_page_size

    attr_writer :maximum_page_size

    attr_writer :use_text_errors

    attr_writer :top_level_links_include_pagination

    attr_writer :top_level_meta_include_record_count

    attr_writer :top_level_meta_record_count_key

    attr_writer :exception_class_whitelist

    attr_writer :always_include_to_one_linkage_data

    attr_writer :always_include_to_many_linkage_data

    attr_writer :raise_if_parameters_not_allowed
  end

  class << self
    attr_accessor :configuration
  end

  @configuration ||= Configuration.new

  def self.configure
    yield(@configuration)
  end
end
