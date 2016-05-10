require 'jsonapi/operation'
require 'jsonapi/paginator'

module JSONAPI
  class RequestParser
    attr_accessor :params, :warnings, :server_error_callbacks,
    :resource_klass, :context, :key_formatter, :cache_serializer

    def initialize(params = nil, options = {})
      @params = params
      @server_error_callbacks = options.fetch(:server_error_callbacks, [])
      @resource_klass = Resource.resource_for(params[:controller]) if params && params[:controller]
      @context = options[:context]
      @key_formatter = options.fetch(:key_formatter, JSONAPI.configuration.key_formatter)
      @cache_serializer = nil

      @warnings = []
      @fields = nil
      @filters = nil
      @sort_criteria = nil
      @source_klass = nil
      @source_id = nil
      @include_directives = nil
      @paginator = nil
      @relationship = nil
    end

    def operations
      return [] if params.nil?

      setup_action_method_name = "setup_#{params[:action]}_action"
      if respond_to?(setup_action_method_name)
        Array.wrap(send(setup_action_method_name))
      else
        fail JSONAPI::Exceptions::InternalServerError.new("Invalid action #{params[:action].inspect}")
      end
    rescue ActionController::ParameterMissing => e
      raise JSONAPI::Exceptions::ParameterMissing.new(e.param)
    end

    def setup_index_action
      JSONAPI::Operation.new(:find,
      resource_klass,
      context: context,
      filters: filters,
      include_directives: include_directives,
      sort_criteria: sort_criteria,
      paginator: paginator,
      fields: fields,
      cache_serializer: cache_serializer
      )
    end

    def setup_get_related_resource_action
      JSONAPI::Operation.new(:show_related_resource,
      resource_klass,
      context: context,
      relationship_type: params[:relationship],
      include_directives: include_directives,
      source_klass: source_klass,
      source_id: source_id,
      fields: fields,
      cache_serializer: cache_serializer
      )
    end

    def setup_get_related_resources_action
      JSONAPI::Operation.new(:show_related_resources,
      resource_klass,
      context: context,
      relationship_type: params[:relationship],
      source_klass: source_klass,
      source_id: source_id,
      filters: source_klass.verify_filters(filters, context),
      include_directives: include_directives,
      sort_criteria: sort_criteria,
      paginator: paginator,
      fields: fields,
      cache_serializer: cache_serializer
      )
    end

    def setup_show_action
      JSONAPI::Operation.new(:show,
      resource_klass,
      context: context,
      id: params[:id],
      include_directives: include_directives,
      fields: fields,
      cache_serializer: cache_serializer
      )
    end

    def setup_show_relationship_action
      JSONAPI::Operation.new(:show_relationship,
      resource_klass,
      context: context,
      relationship_type: params[:relationship],
      parent_key: resource_klass.verify_key(params.require(@resource_klass._as_parent_key))
      )
    end

    def setup_create_action
      data = params.require(:data)
      JSONAPI::Exceptions::AggregatedError.rescuing_map(Array.wrap(data)) do |raw_obj|
        verify_type(raw_obj[:type])
        JSONAPI::Operation.new(:create_resource,
          resource_klass,
          context: context,
          data: parse_params(creatable_fields, raw_obj),
          fields: fields
        )
      end
    end

    def setup_create_relationship_action
      return [] unless relationship.is_a?(JSONAPI::Relationship::ToMany)
      JSONAPI::Operation.new(:create_to_many_relationship,
        resource_klass,
        context: context,
        resource_id: params.require(resource_klass._as_parent_key),
        relationship_type: relationship.name,
        data: relationship_params[:to_many].values[0]
      )
    end

    def setup_update_relationship_action
      options = {
        context: context,
        resource_id: params.require(resource_klass._as_parent_key),
        relationship_type: relationship.name
      }

      verified_params = self.relationship_params

      if relationship.is_a?(JSONAPI::Relationship::ToOne)
        if relationship.polymorphic?
          options[:key_value] = verified_params[:to_one].values[0][:id]
          options[:key_type] = verified_params[:to_one].values[0][:type]

          operation_type = :replace_polymorphic_to_one_relationship
        else
          options[:key_value] = verified_params[:to_one].values[0]
          operation_type = :replace_to_one_relationship
        end
      elsif relationship.is_a?(JSONAPI::Relationship::ToMany)
        unless relationship.acts_as_set
          fail JSONAPI::Exceptions::ToManySetReplacementForbidden.new
        end
        options[:data] = verified_params[:to_many].values[0]
        operation_type = :replace_to_many_relationship
      end

      JSONAPI::Operation.new(operation_type, resource_klass, options)
    end

    def setup_update_action
      data = Array.wrap(params.require(:data))
      keys = Array.wrap(params[:id])

      if params.has_key?(:id)
        fail JSONAPI::Exceptions::CountMismatch if keys.count != data.count
      end

      id_key_presence_check_required = params[:data].is_a?(Array) || params.has_key?(:id)

      JSONAPI::Exceptions::AggregatedError.rescuing_map(data) do |object_params|
        fail JSONAPI::Exceptions::MissingKey.new if object_params[:id].nil?

        key = object_params[:id].to_s
        if id_key_presence_check_required && !keys.include?(key)
          fail JSONAPI::Exceptions::KeyNotIncludedInURL.new(key)
        end

        object_params.delete(:id) unless keys.include?(:id)

        verify_type(object_params[:type])

        JSONAPI::Operation.new(:replace_fields,
          @resource_klass,
          context: @context,
          resource_id: key,
          data: parse_params(updatable_fields, object_params),
          fields: fields
        )
      end
    end

    def setup_destroy_action
      keys = parse_key_array(params.require(:id))

      keys.map do |key|
        JSONAPI::Operation.new(:remove_resource,
          @resource_klass,
          context: @context,
          resource_id: key
        )
      end
    end

    def setup_destroy_relationship_action
      operation_args = {
        context: context,
        resource_id: params.require(resource_klass._as_parent_key),
        relationship_type: relationship.name
      }

      if relationship.is_a?(JSONAPI::Relationship::ToMany)
        return relationship_params[:to_many].values.first.map do |key|
          JSONAPI::Operation.new(
            :remove_to_many_relationship,
            resource_klass,
            operation_args.merge(associated_key: key)
          )
        end
      else
        return JSONAPI::Operation.new(
          :remove_to_one_relationship,
          resource_klass,
          operation_args
        )
      end
    end

    def source_klass
      return @source_klass unless @source_klass.nil?
      @source_klass = Resource.resource_for(params.require(:source))
    end

    def source_id
      return @source_id unless @source_id.nil?
      @source_id = source_klass.verify_key(params.require(source_klass._as_parent_key), @context)
    end

    def relationship
      return @relationship unless @relationship.nil?
      return nil unless params.has_key?(:relationship)
      @relationship = resource_klass._relationship(params.require(:relationship))
    end

    def relationship_params
      parse_params(updatable_fields, { relationships: {
        format_key(relationship.name) => { data: params.fetch(:data) }
      }})
    end

    def paginator
      return @paginator unless @paginator.nil?

      paginator_name = @resource_klass._paginator
      return nil if paginator_name == :none

      @paginator = JSONAPI::Paginator.paginator_for(paginator_name).new(params[:page])
    end

    def fields
      return @fields unless @fields.nil?
      return @fields = {} if params[:fields].nil?

      extracted_fields = {}

      # Extract the fields for each type from the fields parameters
      if params[:fields].is_a?(ActionController::Parameters)
        params[:fields].each do |field, value|
          resource_fields = value.split(',') unless value.nil? || value.empty?
          extracted_fields[field] = resource_fields
        end
      else
        fail JSONAPI::Exceptions::InvalidFieldFormat.new
      end

      # Validate the fields
      JSONAPI::Exceptions::AggregatedError.rescuing_each(extracted_fields) do |type, values|
        underscored_type = unformat_key(type)
        extracted_fields[type] = []
        begin
          if type != format_key(type)
            fail JSONAPI::Exceptions::InvalidResource.new(type)
          end
          type_resource = Resource.resource_for(@resource_klass.module_path + underscored_type.to_s)
        rescue NameError
          fail JSONAPI::Exceptions::InvalidResource.new(type)
        end

        if type_resource.nil?
          fail JSONAPI::Exceptions::InvalidResource.new(type)
        else
          unless values.nil?
            valid_fields = type_resource.fields.collect { |key| format_key(key) }
            values.each do |field|
              if valid_fields.include?(field)
                extracted_fields[type].push unformat_key(field)
              else
                fail JSONAPI::Exceptions::InvalidField.new(type, field)
              end
            end
          else
            fail JSONAPI::Exceptions::InvalidField.new(type, 'nil')
          end
        end
      end

      @fields = extracted_fields.deep_transform_keys { |key| unformat_key(key) }
    end

    def check_include(resource_klass, include_parts)
      rel_name = unformat_key(include_parts.first)
      rel = resource_klass._relationship(rel_name)

      if rel && format_key(rel_name) == include_parts.first
        unless include_parts.last.empty?
          check_include(
            Resource.resource_for(@resource_klass.module_path + rel.class_name.to_s.underscore),
            include_parts.last.partition('.')
          )
        end
      else
        fail JSONAPI::Exceptions::InvalidInclude.new(format_key(resource_klass._type),
                                                               include_parts.first)
      end
    end

    def include_directives
      return @include_directives unless @include_directives.nil?
      return nil if params[:include].nil?

      unless JSONAPI.configuration.allow_include
        fail JSONAPI::Exceptions::ParametersNotAllowed.new([:include])
      end

      included_resources = CSV.parse_line(params[:include])
      return nil if included_resources.nil?

      includes = JSONAPI::Exceptions::AggregatedError.rescuing_map(included_resources) do |included_resource|
        check_include(@resource_klass, included_resource.partition('.'))
        unformat_key(included_resource).to_s
      end

      @include_directives = JSONAPI::IncludeDirectives.new(includes)
    end

    def filters
      return @filters unless @filters.nil?

      @filters = {}
      @resource_klass._allowed_filters.each do |filter, opts|
        next if opts[:default].nil? || !@filters[filter].nil?
        @filters[filter] = opts[:default]
      end

      filter_params = params[:filter]
      return @filters unless filter_params
      filter_params = filter_params.to_unsafe_h if filter_params.respond_to?(:to_unsafe_h)

      unless JSONAPI.configuration.allow_filter
        fail JSONAPI::Exceptions::ParametersNotAllowed.new([:filter])
      end

      unless filter_params.respond_to?(:each)
        fail JSONAPI::Exceptions::InvalidFiltersSyntax.new(filter_params)
      end

      @filters = {}
      JSONAPI::Exceptions::AggregatedError.rescuing_each(filter_params) do |key, value|
        filter = unformat_key(key)
        if @resource_klass._allowed_filter?(filter)
          @filters[filter] = value
        else
          fail JSONAPI::Exceptions::FilterNotAllowed.new(filter)
        end
      end
      return @filters
    end

    def sort_criteria
      return @sort_criteria unless @sort_criteria.nil?

      unless params[:sort].present?
        return @sort_criteria = [{ field: 'id', direction: :asc }]
      end

      unless JSONAPI.configuration.allow_sort
        fail JSONAPI::Exceptions::ParametersNotAllowed.new([:sort])
      end

      sortable_fields = @resource_klass.sortable_fields(context)

      @sort_criteria = CSV.parse_line(URI.unescape(params[:sort])).map do |sort|
        if sort.start_with?('-')
          criterion = { field: unformat_key(sort[1..-1]).to_s, direction: :desc }
        else
          criterion = { field: unformat_key(sort).to_s, direction: :asc }
        end

        unless sortable_fields.include? criterion[:field].to_sym
          fail JSONAPI::Exceptions::InvalidSortCriteria
                           .new(format_key(@resource_klass._type), criterion[:field])
        end

        criterion
      end
    end

    # TODO: Please remove after `createable_fields` is removed
    # :nocov:
    def creatable_fields
      if @resource_klass.respond_to?(:createable_fields)
        creatable_fields = @resource_klass.createable_fields(@context)
      else
        creatable_fields = @resource_klass.creatable_fields(@context)
      end
    end
    # :nocov:

    def verify_type(type)
      if type.nil?
        fail JSONAPI::Exceptions::ParameterMissing.new(:type)
      elsif unformat_key(type).to_sym != @resource_klass._type
        fail JSONAPI::Exceptions::InvalidResource.new(type)
      end
    end

    def parse_to_one_links_object(raw)
      if raw.nil?
        return {
          type: nil,
          id: nil
        }
      end

      if !(raw.is_a?(Hash) || raw.is_a?(ActionController::Parameters)) ||
         raw.keys.length != 2 || !(raw.key?('type') && raw.key?('id'))
        fail JSONAPI::Exceptions::InvalidLinksObject.new
      end

      {
        type: unformat_key(raw['type']).to_s,
        id: raw['id']
      }
    end

    def parse_to_many_links_object(raw)
      fail JSONAPI::Exceptions::InvalidLinksObject.new if raw.nil?

      links_object = {}
      if raw.is_a?(Array)
        raw.each do |link|
          link_object = parse_to_one_links_object(link)
          links_object[link_object[:type]] ||= []
          links_object[link_object[:type]].push(link_object[:id])
        end
      else
        fail JSONAPI::Exceptions::InvalidLinksObject.new
      end
      links_object
    end

    def parse_params(allowed_fields, obj_params)
      verify_permitted_params(allowed_fields, obj_params)

      checked_attributes = {}
      checked_to_one_relationships = {}
      checked_to_many_relationships = {}

      obj_params.each do |key, value|
        case key.to_s
        when 'relationships'
          value.each do |link_key, link_value|
            param = unformat_key(link_key)
            rel = @resource_klass._relationship(param)

            if rel.is_a?(JSONAPI::Relationship::ToOne)
              checked_to_one_relationships[param] = parse_to_one_relationship(link_value, rel)
            elsif rel.is_a?(JSONAPI::Relationship::ToMany)
              parse_to_many_relationship(link_value, rel) do |result_val|
                checked_to_many_relationships[param] = result_val
              end
            end
          end
        when 'id'
          checked_attributes['id'] = unformat_value(:id, value)
        when 'attributes'
          value.each do |attr_key, attr_value|
            param = unformat_key(attr_key)
            checked_attributes[param] = unformat_value(param, attr_value)
          end
        end
      end

      return {
        'attributes' => checked_attributes,
        'to_one' => checked_to_one_relationships,
        'to_many' => checked_to_many_relationships
      }.deep_transform_keys { |key| unformat_key(key) }
    end

    def parse_to_one_relationship(link_value, relationship)
      if link_value.nil?
        linkage = nil
      else
        linkage = link_value[:data]
      end

      links_object = parse_to_one_links_object(linkage)
      if !relationship.polymorphic? && links_object[:type] && (links_object[:type].to_s != relationship.type.to_s)
        fail JSONAPI::Exceptions::TypeMismatch.new(links_object[:type])
      end

      unless links_object[:id].nil?
        resource = self.resource_klass || Resource
        relationship_resource = resource.resource_for(unformat_key(links_object[:type]).to_s)
        relationship_id = relationship_resource.verify_key(links_object[:id], @context)
        if relationship.polymorphic?
          { id: relationship_id, type: unformat_key(links_object[:type].to_s) }
        else
          relationship_id
        end
      else
        nil
      end
    end

    def parse_to_many_relationship(link_value, relationship, &add_result)
      if link_value.is_a?(Array) && link_value.length == 0
        linkage = []
      elsif (link_value.is_a?(Hash) || link_value.is_a?(ActionController::Parameters))
        linkage = link_value[:data]
      else
        fail JSONAPI::Exceptions::InvalidLinksObject.new
      end

      links_object = parse_to_many_links_object(linkage)

      # Since we do not yet support polymorphic to_many relationships we will raise an error if the type does not match the
      # relationship's type.
      # ToDo: Support Polymorphic relationships

      if links_object.length == 0
        add_result.call([])
      else
        if links_object.length > 1 || !links_object.has_key?(unformat_key(relationship.type).to_s)
          fail JSONAPI::Exceptions::TypeMismatch.new(links_object[:type])
        end

        links_object.each_pair do |type, keys|
          relationship_resource = Resource.resource_for(@resource_klass.module_path + unformat_key(type).to_s)
          add_result.call relationship_resource.verify_keys(keys, @context)
        end
      end
    end

    def unformat_value(attribute, value)
      value_formatter = JSONAPI::ValueFormatter.value_formatter_for(@resource_klass._attribute_options(attribute)[:format])
      value_formatter.unformat(value)
    end

    def verify_permitted_params(allowed_fields, obj_params)
      formatted_allowed_fields = allowed_fields.collect { |field| format_key(field).to_sym }
      params_not_allowed = []

      obj_params.each do |key, value|
        case key.to_s
        when 'relationships'
          value.keys.each do |links_key|
            unless formatted_allowed_fields.include?(links_key.to_sym)
              params_not_allowed.push(links_key)
              unless JSONAPI.configuration.raise_if_parameters_not_allowed
                value.delete links_key
              end
            end
          end
        when 'attributes'
          value.each do |attr_key, attr_value|
            unless formatted_allowed_fields.include?(attr_key.to_sym)
              params_not_allowed.push(attr_key)
              unless JSONAPI.configuration.raise_if_parameters_not_allowed
                value.delete attr_key
              end
            end
          end
        when 'type'
        when 'id'
          unless formatted_allowed_fields.include?(:id)
            params_not_allowed.push(:id)
            unless JSONAPI.configuration.raise_if_parameters_not_allowed
              obj_params.delete :id
            end
          end
        else
          params_not_allowed.push(key)
        end
      end

      if params_not_allowed.length > 0
        if JSONAPI.configuration.raise_if_parameters_not_allowed
          fail JSONAPI::Exceptions::ParametersNotAllowed.new(params_not_allowed)
        else
          params_not_allowed_warnings = params_not_allowed.map do |key|
            JSONAPI::Warning.new(code: JSONAPI::PARAM_NOT_ALLOWED,
                                 title: 'Param not allowed',
                                 detail: "#{key} is not allowed.")
          end
          self.warnings.concat(params_not_allowed_warnings)
        end
      end
    end

    # TODO: Please remove after `updateable_fields` is removed
    # :nocov:
    def updatable_fields
      if @resource_klass.respond_to?(:updateable_fields)
        @resource_klass.updateable_fields(@context)
      else
        @resource_klass.updatable_fields(@context)
      end
    end
    # :nocov:

    def parse_key_array(raw)
      @resource_klass.verify_keys(raw.split(/,/), context)
    end

    def format_key(key)
      @key_formatter.format(key)
    end

    def unformat_key(key)
      @key_formatter.unformat(key).try(:to_sym)
    end
  end
end
