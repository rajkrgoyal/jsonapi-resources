require 'jsonapi/callbacks'

module JSONAPI
  class Resource
    include Callbacks

    attr_reader :context

    define_jsonapi_resources_callbacks :create,
                                       :update,
                                       :remove,
                                       :save,
                                       :create_to_many_link,
                                       :replace_to_many_links,
                                       :create_to_one_link,
                                       :replace_to_one_link,
                                       :replace_polymorphic_to_one_link,
                                       :remove_to_many_link,
                                       :remove_to_one_link,
                                       :replace_fields

    def initialize(model, context)
      @model = model
      @context = context
    end

    def _model
      @model
    end

    def id
      _model.public_send(self.class._primary_key)
    end

    def cache_id
      [id, _model.public_send(self.class._cache_field)]
    end

    def is_new?
      id.nil?
    end

    def change(callback)
      completed = false

      if @changing
        run_callbacks callback do
          completed = (yield == :completed)
        end
      else
        run_callbacks is_new? ? :create : :update do
          @changing = true
          run_callbacks callback do
            completed = (yield == :completed)
          end

          completed = (save == :completed) if @save_needed || is_new?
        end
      end

      return completed ? :completed : :accepted
    end

    def remove
      run_callbacks :remove do
        _remove
      end
    end

    def create_to_many_links(relationship_type, relationship_key_values)
      change :create_to_many_link do
        _create_to_many_links(relationship_type, relationship_key_values)
      end
    end

    def replace_to_many_links(relationship_type, relationship_key_values)
      change :replace_to_many_links do
        _replace_to_many_links(relationship_type, relationship_key_values)
      end
    end

    def replace_to_one_link(relationship_type, relationship_key_value)
      change :replace_to_one_link do
        _replace_to_one_link(relationship_type, relationship_key_value)
      end
    end

    def replace_polymorphic_to_one_link(relationship_type, relationship_key_value, relationship_key_type)
      change :replace_polymorphic_to_one_link do
        _replace_polymorphic_to_one_link(relationship_type, relationship_key_value, relationship_key_type)
      end
    end

    def remove_to_many_link(relationship_type, key)
      change :remove_to_many_link do
        _remove_to_many_link(relationship_type, key)
      end
    end

    def remove_to_one_link(relationship_type)
      change :remove_to_one_link do
        _remove_to_one_link(relationship_type)
      end
    end

    def replace_fields(field_data)
      change :replace_fields do
        _replace_fields(field_data)
      end
    end

    # Override this on a resource instance to override the fetchable keys
    def fetchable_fields
      self.class.fields
    end

    # Override this on a resource to customize how the associated records
    # are fetched for a model. Particularly helpful for authorization.
    def records_for(relation_name)
      _model.public_send relation_name
    end

    def model_error_messages
      _model.errors.messages
    end

    # Add metadata to validation error objects.
    #
    # Suppose `model_error_messages` returned the following error messages
    # hash:
    #
    #   {password: ["too_short", "format"]}
    #
    # Then to add data to the validation error `validation_error_metadata`
    # could return:
    #
    #   {
    #     password: {
    #       "too_short": {"minimum_length" => 6},
    #       "format": {"requirement" => "must contain letters and numbers"}
    #     }
    #   }
    #
    # The specified metadata is then be merged into the validation error
    # object.
    def validation_error_metadata
      {}
    end

    # Override this to return resource level meta data
    # must return a hash, and if the hash is empty the meta section will not be serialized with the resource
    # meta keys will be not be formatted with the key formatter for the serializer by default. They can however use the
    # serializer's format_key and format_value methods if desired
    # the _options hash will contain the serializer and the serialization_options
    def meta(_options)
      {}
    end

    # Override this to return custom links
    # must return a hash, which will be merged with the default { self: 'self-url' } links hash
    # links keys will be not be formatted with the key formatter for the serializer by default.
    # They can however use the serializer's format_key and format_value methods if desired
    # the _options hash will contain the serializer and the serialization_options
    def custom_links(_options)
      {}
    end

    def preloaded_fragments
      # A hash of hashes
      @preloaded_fragments ||= Hash.new
    end

    private

    def save
      run_callbacks :save do
        _save
      end
    end

    # Override this on a resource to return a different result code. Any
    # value other than :completed will result in operations returning
    # `:accepted`
    #
    # For example to return `:accepted` if your model does not immediately
    # save resources to the database you could override `_save` as follows:
    #
    # ```
    # def _save
    #   super
    #   return :accepted
    # end
    # ```
    def _save(validation_context = nil)
      unless @model.valid?(validation_context)
        fail JSONAPI::Exceptions::ValidationErrors.new(self)
      end

      if defined? @model.save
        saved = @model.save(validate: false)
        unless saved
          if @model.errors.present?
            fail JSONAPI::Exceptions::ValidationErrors.new(self)
          else
            fail JSONAPI::Exceptions::SaveFailed.new
          end
        end
      else
        saved = true
      end

      @save_needed = !saved

      :completed
    end

    def _remove
      unless @model.destroy
        fail JSONAPI::Exceptions::ValidationErrors.new(self)
      end
      :completed

    rescue ActiveRecord::DeleteRestrictionError => e
      fail JSONAPI::Exceptions::RecordLocked.new(e.message)
    end

    def _create_to_many_links(relationship_type, relationship_key_values)
      relationship = self.class._relationships[relationship_type]

      relationship_key_values.each do |relationship_key_value|
        related_resource = relationship.resource_klass.find_by_key(relationship_key_value, context: @context)

        relation_name = relationship.relation_name(context: @context)
        # TODO: Add option to skip relations that already exist instead of returning an error?
        relation = @model.public_send(relation_name).where(relationship.primary_key => relationship_key_value).first
        if relation.nil?
          @model.public_send(relation_name) << related_resource._model
        else
          fail JSONAPI::Exceptions::HasManyRelationExists.new(relationship_key_value)
        end
      end

      :completed
    end

    def _replace_to_many_links(relationship_type, relationship_key_values)
      relationship = self.class._relationships[relationship_type]
      send("#{relationship.foreign_key}=", relationship_key_values)
      @save_needed = true

      :completed
    end

    def _replace_to_one_link(relationship_type, relationship_key_value)
      relationship = self.class._relationships[relationship_type]

      send("#{relationship.foreign_key}=", relationship_key_value)
      @save_needed = true

      :completed
    end

    def _replace_polymorphic_to_one_link(relationship_type, key_value, key_type)
      relationship = self.class._relationships[relationship_type.to_sym]

      _model.public_send("#{relationship.foreign_key}=", key_value)
      _model.public_send("#{relationship.polymorphic_type}=", key_type.to_s.classify)

      @save_needed = true

      :completed
    end

    def _remove_to_many_link(relationship_type, key)
      relation_name = self.class._relationships[relationship_type].relation_name(context: @context)

      @model.public_send(relation_name).delete(key)

      :completed

    rescue ActiveRecord::DeleteRestrictionError => e
      fail JSONAPI::Exceptions::RecordLocked.new(e.message)
    rescue ActiveRecord::RecordNotFound
      fail JSONAPI::Exceptions::RecordNotFound.new(key)
    end

    def _remove_to_one_link(relationship_type)
      relationship = self.class._relationships[relationship_type]

      send("#{relationship.foreign_key}=", nil)
      @save_needed = true

      :completed
    end

    def _replace_fields(field_data)
      field_data[:attributes].each do |attribute, value|
        begin
          send "#{attribute}=", value
          @save_needed = true
        rescue ArgumentError
          # :nocov: Will be thrown if an enum value isn't allowed for an enum. Currently not tested as enums are a rails 4.1 and higher feature
          raise JSONAPI::Exceptions::InvalidFieldValue.new(attribute, value)
          # :nocov:
        end
      end

      field_data[:to_one].each do |relationship_type, value|
        if value.nil?
          remove_to_one_link(relationship_type)
        else
          case value
          when Hash
            replace_polymorphic_to_one_link(relationship_type.to_s, value.fetch(:id), value.fetch(:type))
          else
            replace_to_one_link(relationship_type, value)
          end
        end
      end if field_data[:to_one]

      field_data[:to_many].each do |relationship_type, values|
        replace_to_many_links(relationship_type, values)
      end if field_data[:to_many]

      :completed
    end

    class << self
      def inherited(subclass)
        subclass.abstract(false)
        subclass.immutable(false)
        subclass.caching(false)
        subclass._attributes = (_attributes || {}).dup
        subclass._model_hints = (_model_hints || {}).dup

        subclass._relationships = {}
        # Add the relationships from the base class to the subclass using the original options
        if _relationships.is_a?(Hash)
          _relationships.each_value do |relationship|
            options = relationship.options.dup
            options[:parent_resource] = subclass
            subclass._add_relationship(relationship.class, relationship.name, options)
          end
        end

        subclass._allowed_filters = (_allowed_filters || Set.new).dup

        type = subclass.name.demodulize.sub(/Resource$/, '').underscore
        subclass._type = type.pluralize.to_sym

        subclass.attribute :id, format: :id

        check_reserved_resource_name(subclass._type, subclass.name)
      end

      def resource_for(type)
        type_with_module = type.include?('/') ? type : module_path + type

        resource_name = _resource_name_from_type(type_with_module)
        resource = resource_name.safe_constantize if resource_name
        if resource.nil?
          fail NameError, "JSONAPI: Could not find resource '#{type}'. (Class #{resource_name} not found)"
        end
        resource
      end

      def resource_for_model(model)
        resource_for(resource_type_for(model))
      end

      def _resource_name_from_type(type)
        "#{type.to_s.underscore.singularize}_resource".camelize
      end

      def resource_type_for(model)
        model_name = model.class.to_s.underscore
        if _model_hints[model_name]
          _model_hints[model_name]
        else
          model_name.rpartition('/').last
        end
      end

      attr_accessor :_attributes, :_relationships, :_type, :_model_hints
      attr_writer :_allowed_filters, :_paginator

      def create(context)
        new(create_model, context)
      end

      def create_model
        _model_class.new
      end

      def routing_options(options)
        @_routing_resource_options = options
      end

      def routing_resource_options
        @_routing_resource_options ||= {}
      end

      # Methods used in defining a resource class
      def attributes(*attrs)
        options = attrs.extract_options!.dup
        attrs.each do |attr|
          attribute(attr, options)
        end
      end

      def attribute(attr, options = {})
        check_reserved_attribute_name(attr)

        if (attr.to_sym == :id) && (options[:format].nil?)
          ActiveSupport::Deprecation.warn('Id without format is no longer supported. Please remove ids from attributes, or specify a format.')
        end

        @_attributes ||= {}
        @_attributes[attr] = options
        define_method attr do
          @model.public_send(options[:delegate] ? options[:delegate].to_sym : attr)
        end unless method_defined?(attr)

        define_method "#{attr}=" do |value|
          @model.public_send("#{options[:delegate] ? options[:delegate].to_sym : attr}=", value)
        end unless method_defined?("#{attr}=")
      end

      def default_attribute_options
        { format: :default }
      end

      def relationship(*attrs)
        options = attrs.extract_options!
        klass = case options[:to]
                  when :one
                    Relationship::ToOne
                  when :many
                    Relationship::ToMany
                  else
                    #:nocov:#
                    fail ArgumentError.new('to: must be either :one or :many')
                    #:nocov:#
                end
        _add_relationship(klass, *attrs, options.except(:to))
      end

      def has_one(*attrs)
        _add_relationship(Relationship::ToOne, *attrs)
      end

      def belongs_to(*attrs)
        ActiveSupport::Deprecation.warn "In #{name} you exposed a `has_one` relationship "\
                                        " using the `belongs_to` class method. We think `has_one`" \
                                        " is more appropriate. If you know what you're doing," \
                                        " and don't want to see this warning again, override the" \
                                        " `belongs_to` class method on your resource."
        _add_relationship(Relationship::ToOne, *attrs)
      end

      def has_many(*attrs)
        _add_relationship(Relationship::ToMany, *attrs)
      end

      def model_name(model, options = {})
        @_model_name = model.to_sym

        model_hint(model: @_model_name, resource: self) unless options[:add_model_hint] == false
      end

      def model_hint(model: _model_name, resource: _type)
        model_name = ((model.is_a?(Class)) && (model < ActiveRecord::Base)) ? model.name : model
        resource_type = ((resource.is_a?(Class)) && (resource < JSONAPI::Resource)) ? resource._type : resource.to_s

        _model_hints[model_name.to_s.gsub('::', '/').underscore] = resource_type.to_s
      end

      def filters(*attrs)
        @_allowed_filters.merge!(attrs.inject({}) { |h, attr| h[attr] = {}; h })
      end

      def filter(attr, *args)
        @_allowed_filters[attr.to_sym] = args.extract_options!
      end

      def primary_key(key)
        @_primary_key = key.to_sym
      end

      def cache_field(field)
        @_cache_field = field.to_sym
      end

      # TODO: remove this after the createable_fields and updateable_fields are phased out
      # :nocov:
      def method_missing(method, *args)
        if method.to_s.match(/createable_fields/)
          ActiveSupport::Deprecation.warn('`createable_fields` is deprecated, please use `creatable_fields` instead')
          creatable_fields(*args)
        elsif method.to_s.match(/updateable_fields/)
          ActiveSupport::Deprecation.warn('`updateable_fields` is deprecated, please use `updatable_fields` instead')
          updatable_fields(*args)
        else
          super
        end
      end
      # :nocov:

      # Override in your resource to filter the updatable keys
      def updatable_fields(_context = nil)
        _updatable_relationships | _attributes.keys - [:id]
      end

      # Override in your resource to filter the creatable keys
      def creatable_fields(_context = nil)
        _updatable_relationships | _attributes.keys
      end

      # Override in your resource to filter the sortable keys
      def sortable_fields(_context = nil)
        _attributes.keys
      end

      def fields
        _relationships.keys | _attributes.keys
      end

      def resolve_relationship_names_to_relations(resource_klass, model_includes, options = {})
        case model_includes
          when Array
            return model_includes.map do |value|
              resolve_relationship_names_to_relations(resource_klass, value, options)
            end
          when Hash
            model_includes.keys.each do |key|
              relationship = resource_klass._relationships[key]
              value = model_includes[key]
              model_includes.delete(key)
              model_includes[relationship.relation_name(options)] = resolve_relationship_names_to_relations(relationship.resource_klass, value, options)
            end
            return model_includes
          when Symbol
            relationship = resource_klass._relationships[model_includes]
            return relationship.relation_name(options)
        end
      end

      def apply_includes(records, options = {})
        include_directives = options[:include_directives]
        if include_directives
          model_includes = resolve_relationship_names_to_relations(self, include_directives.model_includes, options)
          records = records.includes(model_includes)
        end

        records
      end

      def apply_pagination(records, paginator, order_options)
        records = paginator.apply(records, order_options) if paginator
        records
      end

      def apply_sort(records, order_options, _context = {})
        if order_options.any?
           order_options.each_pair do |field, direction|
            if field.to_s.include?(".")
              *model_names, column_name = field.split(".")

              associations = _lookup_association_chain([records.model.to_s, *model_names])
              joins_query = _build_joins([records.model, *associations])

              # _sorting is appended to avoid name clashes with manual joins eg. overriden filters
              order_by_query = "#{associations.last.name}_sorting.#{column_name} #{direction}"
              records = records.joins(joins_query).order(order_by_query)
            else
              records = records.order(field => direction)
            end
          end
        end

        records
      end

      def _lookup_association_chain(model_names)
        associations = []
        model_names.inject do |prev, current|
          association = prev.classify.constantize.reflect_on_all_associations.detect do |assoc|
            assoc.name.to_s.downcase == current.downcase
          end
          associations << association
          association.class_name
        end

        associations
      end

      def _build_joins(associations)
        joins = []

        associations.inject do |prev, current|
          joins << "LEFT JOIN #{current.table_name} AS #{current.name}_sorting ON #{current.name}_sorting.id = #{prev.table_name}.#{current.foreign_key}"
          current
        end
        joins.join("\n")
      end

      def apply_filter(records, filter, value, options = {})
        strategy = _allowed_filters.fetch(filter.to_sym, Hash.new)[:apply]

        if strategy
          if strategy.is_a?(Symbol) || strategy.is_a?(String)
            send(strategy, records, value, options)
          else
            strategy.call(records, value, options)
          end
        else
          records.where(filter => value)
        end
      end

      def apply_filters(records, filters, options = {})
        required_includes = []

        if filters
          filters.each do |filter, value|
            if _relationships.include?(filter)
              if _relationships[filter].belongs_to?
                records = apply_filter(records, _relationships[filter].foreign_key, value, options)
              else
                required_includes.push(filter.to_s)
                records = apply_filter(records, "#{_relationships[filter].table_name}.#{_relationships[filter].primary_key}", value, options)
              end
            else
              records = apply_filter(records, filter, value, options)
            end
          end
        end

        if required_includes.any?
          records = apply_includes(records, options.merge(include_directives: IncludeDirectives.new(required_includes)))
        end

        records
      end

      def filter_records(filters, options, records = records(options))
        records = apply_filters(records, filters, options)
        apply_includes(records, options)
      end

      def sort_records(records, order_options, context = {})
        apply_sort(records, order_options, context)
      end

      # Assumes ActiveRecord's counting. Override if you need a different counting method
      def count_records(records)
        records.count(:all)
      end

      def find_count(filters, options = {})
        count_records(filter_records(filters, options))
      end

      def find(filters, options = {})
        resources_for(find_records(filters, options), options[:context])
      end

      def resources_for(records, context)
        resource_classes = {}
        records.map do |model|
          resource_class = resource_classes[model.class] ||= self.resource_for_model(model)
          resource_class.new(model, context)
        end
      end

      def find_serialized_with_caching(filters_or_source, serializer, options = {})
        if filters_or_source.is_a?(ActiveRecord::Relation)
          records = filters_or_source
        elsif _model_class.respond_to?(:all) && _model_class.respond_to?(:arel_table)
          records = find_records(filters_or_source, options.except(:include_directives))
        else
          records = find(filters_or_source, options)
        end
        cached_resources_for(records, serializer, options)
      end

      def find_by_key(key, options = {})
        context = options[:context]
        records = find_records({_primary_key => key}, options.except(:paginator, :sort_criteria))
        model = records.first
        fail JSONAPI::Exceptions::RecordNotFound.new(key) if model.nil?
        self.resource_for_model(model).new(model, context)
      end

      def find_by_key_serialized_with_caching(key, serializer, options = {})
        if _model_class.respond_to?(:all) && _model_class.respond_to?(:arel_table)
          results = find_serialized_with_caching({_primary_key => key}, serializer, options)
          result = results.first
          fail JSONAPI::Exceptions::RecordNotFound.new(key) if result.nil?
          return result
        else
          resource = find_by_key(key, options)
          return cached_resources_for([resource], serializer, options).first
        end
      end

      # Override this method if you want to customize the relation for
      # finder methods (find, find_by_key, find_serialized_with_caching)
      def records(_options = {})
        _model_class.all
      end

      def verify_filters(filters, context = nil)
        verified_filters = {}
        filters.each do |filter, raw_value|
          verified_filter = verify_filter(filter, raw_value, context)
          verified_filters[verified_filter[0]] = verified_filter[1]
        end
        verified_filters
      end

      def is_filter_relationship?(filter)
        filter == _type || _relationships.include?(filter)
      end

      def verify_filter(filter, raw, context = nil)
        filter_values = []
        if raw.present?
          filter_values += raw.is_a?(String) ? CSV.parse_line(raw) : [raw]
        end

        strategy = _allowed_filters.fetch(filter, Hash.new)[:verify]

        if strategy
          if strategy.is_a?(Symbol) || strategy.is_a?(String)
            values = send(strategy, filter_values, context)
          else
            values = strategy.call(filter_values, context)
          end
          [filter, values]
        else
          if is_filter_relationship?(filter)
            verify_relationship_filter(filter, filter_values, context)
          else
            verify_custom_filter(filter, filter_values, context)
          end
        end
      end

      def key_type(key_type)
        @_resource_key_type = key_type
      end

      def resource_key_type
        @_resource_key_type ||= JSONAPI.configuration.resource_key_type
      end

      def verify_key(key, context = nil)
        key_type = resource_key_type

        case key_type
        when :integer
          return if key.nil?
          Integer(key)
        when :string
          return if key.nil?
          if key.to_s.include?(',')
            raise JSONAPI::Exceptions::InvalidFieldValue.new(:id, key)
          else
            key
          end
        when :uuid
          return if key.nil?
          if key.to_s.match(/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/)
            key
          else
            raise JSONAPI::Exceptions::InvalidFieldValue.new(:id, key)
          end
        else
          key_type.call(key, context)
        end
      rescue
        raise JSONAPI::Exceptions::InvalidFieldValue.new(:id, key)
      end

      # override to allow for key processing and checking
      def verify_keys(keys, context = nil)
        return keys.collect do |key|
          verify_key(key, context)
        end
      end

      # Either add a custom :verify labmda or override verify_custom_filter to allow for custom filters
      def verify_custom_filter(filter, value, _context = nil)
        [filter, value]
      end

      # Either add a custom :verify labmda or override verify_relationship_filter to allow for custom
      # relationship logic, such as uuids, multiple keys or permission checks on keys
      def verify_relationship_filter(filter, raw, _context = nil)
        [filter, raw]
      end

      # quasi private class methods
      def _attribute_options(attr)
        default_attribute_options.merge(@_attributes[attr])
      end

      def _updatable_relationships
        @_relationships.map { |key, _relationship| key }
      end

      def _relationship(type)
        type = type.to_sym
        @_relationships[type]
      end

      def _model_name
        if _abstract
          return ''
        else
          return @_model_name if defined?(@_model_name)
          class_name = self.name
          return '' if class_name.nil?
          return @_model_name = class_name.demodulize.sub(/Resource$/, '')
        end
      end

      def _primary_key
        @_primary_key ||= _model_class.respond_to?(:primary_key) ? _model_class.primary_key : :id
      end

      def _cache_field
        @_cache_field ||= JSONAPI.configuration.default_resource_cache_field
      end

      def _table_name
        @_table_name ||= _model_class.respond_to?(:table_name) ? _model_class.table_name : _model_name.tableize
      end

      def _as_parent_key
        @_as_parent_key ||= "#{_type.to_s.singularize}_id"
      end

      def _allowed_filters
        defined?(@_allowed_filters) ? @_allowed_filters : { id: {} }
      end

      def _paginator
        @_paginator ||= JSONAPI.configuration.default_paginator
      end

      def paginator(paginator)
        @_paginator = paginator
      end

      def abstract(val = true)
        @abstract = val
      end

      def _abstract
        @abstract
      end

      def immutable(val = true)
        @immutable = val
      end

      def _immutable
        @immutable
      end

      def mutable?
        !@immutable
      end

      def caching(val = true)
        @caching = val
      end

      def _caching
        @caching
      end

      def caching?
        @caching && !JSONAPI.configuration.resource_cache.nil?
      end

      def attribute_caching_context(context)
        nil
      end

      def _model_class
        return nil if _abstract

        return @model if defined?(@model)
        return nil if self.name.to_s.blank? && _model_name.to_s.blank?
        @model = _model_name.to_s.safe_constantize
        warn "[MODEL NOT FOUND] Model could not be found for #{self.name}. If this a base Resource declare it as abstract." if @model.nil?
        @model
      end

      def _allowed_filter?(filter)
        !_allowed_filters[filter].nil?
      end

      def module_path
        if name == 'JSONAPI::Resource'
          ''
        else
          name =~ /::[^:]+\Z/ ? ($`.freeze.gsub('::', '/') + '/').underscore : ''
        end
      end

      def construct_order_options(sort_params)
        return {} unless sort_params

        sort_params.each_with_object({}) do |sort, order_hash|
          field = sort[:field] == 'id' ? _primary_key : sort[:field]
          order_hash[field] = sort[:direction]
        end
      end

      def _add_relationship(klass, *attrs)
        options = attrs.extract_options!
        options[:parent_resource] = self

        attrs.each do |attr|
          relationship_name = attr.to_sym

          check_reserved_relationship_name(relationship_name)

          # Initialize from an ActiveRecord model's properties
          if _model_class && _model_class.ancestors.collect{|ancestor| ancestor.name}.include?('ActiveRecord::Base')
            model_association = _model_class.reflect_on_association(relationship_name)
            if model_association
              options[:class_name] ||= model_association.class_name
            end
          end

          @_relationships[relationship_name] = relationship = klass.new(relationship_name, options)

          associated_records_method_name = case relationship
                                           when JSONAPI::Relationship::ToOne then "record_for_#{relationship_name}"
                                           when JSONAPI::Relationship::ToMany then "records_for_#{relationship_name}"
                                           end

          foreign_key = relationship.foreign_key

          define_method "#{foreign_key}=" do |value|
            @model.method("#{foreign_key}=").call(value)
          end unless method_defined?("#{foreign_key}=")

          define_method associated_records_method_name do |opts = {}|
            relationship = self.class._relationships[relationship_name]
            relation_name = relationship.relation_name(context: @context)
            resource_klass = relationship.resource_klass
            records = records_for(relation_name)

            filters = opts.fetch(:filters, {})
            unless filters.nil? || filters.empty?
              records = resource_klass.apply_filters(records, filters, opts)
            end

            sort_criteria =  opts.fetch(:sort_criteria, {})
            unless sort_criteria.nil? || sort_criteria.empty?
              order_options = relationship.resource_klass.construct_order_options(sort_criteria)
              records = resource_klass.apply_sort(records, order_options, @context)
            end

            paginator = opts[:paginator]
            if paginator
              records = resource_klass.apply_pagination(records, paginator, order_options)
            end

            records
          end unless method_defined?(associated_records_method_name)

          if relationship.is_a?(JSONAPI::Relationship::ToOne)
            if relationship.belongs_to?
              define_method foreign_key do
                @model.method(foreign_key).call
              end unless method_defined?(foreign_key)

              define_method relationship_name do |opts = {}|
                relationship = self.class._relationships[relationship_name]

                if relationship.polymorphic?
                  associated_model = public_send(associated_records_method_name)
                  resource_klass = self.class.resource_for_model(associated_model) if associated_model
                  return resource_klass.new(associated_model, @context) if resource_klass
                else
                  resource_klass = relationship.resource_klass
                  if resource_klass
                    associated_model = public_send(associated_records_method_name)
                    return associated_model ? resource_klass.new(associated_model, @context) : nil
                  end
                end
              end unless method_defined?(relationship_name)
            else
              define_method foreign_key do
                relationship = self.class._relationships[relationship_name]

                record = public_send(associated_records_method_name)
                return nil if record.nil?
                record.public_send(relationship.resource_klass._primary_key)
              end unless method_defined?(foreign_key)

              define_method relationship_name do |opts = {}|
                relationship = self.class._relationships[relationship_name]

                resource_klass = relationship.resource_klass
                if resource_klass
                  associated_model = public_send(associated_records_method_name)
                  return associated_model ? resource_klass.new(associated_model, @context) : nil
                end
              end unless method_defined?(relationship_name)
            end
          elsif relationship.is_a?(JSONAPI::Relationship::ToMany)
            define_method foreign_key do
              records = public_send(associated_records_method_name)
              return records.collect do |record|
                record.public_send(relationship.resource_klass._primary_key)
              end
            end unless method_defined?(foreign_key)

            define_method relationship_name do |opts = {}|
              relationship = self.class._relationships[relationship_name]

              resource_klass = relationship.resource_klass
              records = public_send(associated_records_method_name, opts)

              return records.collect do |record|
                if relationship.polymorphic?
                  resource_klass = self.class.resource_for_model(record)
                end
                resource_klass.new(record, @context)
              end
            end unless method_defined?(relationship_name)
          end
        end
      end

      private

      def find_records(filters, options = {})
        context = options[:context]

        records = filter_records(filters, options)

        sort_criteria = options.fetch(:sort_criteria) { [] }
        order_options = construct_order_options(sort_criteria)
        records = sort_records(records, order_options, context)

        records = apply_pagination(records, options[:paginator], order_options)

        records
      end

      def cached_resources_for(records, serializer, options)
        if records.is_a?(Array) && records.all?{|rec| rec.is_a?(JSONAPI::Resource)}
          resources = records.map{|r| [r.id, r] }.to_h
        elsif self.caching?
          t = _model_class.arel_table
          cache_ids = pluck_arel_attributes(records, t[_primary_key], t[_cache_field])
          resources = CachedResourceFragment.fetch_fragments(self, serializer, options[:context], cache_ids)
        else
          resources = resources_for(records, options).map{|r| [r.id, r] }.to_h
        end

        preload_included_fragments(resources, records, serializer, options)

        resources.values
      end

      def check_reserved_resource_name(type, name)
        if [:ids, :types, :hrefs, :links].include?(type)
          warn "[NAME COLLISION] `#{name}` is a reserved resource name."
          return
        end
      end

      def check_reserved_attribute_name(name)
        # Allow :id since it can be used to specify the format. Since it is a method on the base Resource
        # an attribute method won't be created for it.
        if [:type].include?(name.to_sym)
          warn "[NAME COLLISION] `#{name}` is a reserved key in #{_resource_name_from_type(_type)}."
        end
      end

      def check_reserved_relationship_name(name)
        if [:id, :ids, :type, :types].include?(name.to_sym)
          warn "[NAME COLLISION] `#{name}` is a reserved relationship name in #{_resource_name_from_type(_type)}."
        end
      end

      def preload_included_fragments(resources, records, serializer, options)
        return if resources.empty?
        res_ids = resources.keys

        include_directives = options[:include_directives]
        return unless include_directives

        relevant_options = options.except(:include_directives, :order, :paginator)
        context = options[:context]

        # For each association, including indirect associations, find the target record ids.
        # Even if a target class doesn't have caching enabled, we still have to look up
        # and match the target ids here, because we can't use ActiveRecord#includes.
        #
        # Note that `paths` returns partial paths before complete paths, so e.g. the partial
        # fragments for posts.comments will exist before we start working with posts.comments.author
        target_resources = {}
        include_directives.paths.each do |path|
          # If path is [:posts, :comments, :author], then...
          pluck_attrs = [] # [posts.id, comments.id, authors.id, authors.updated_at]
          pluck_attrs << self._model_class.arel_table[self._primary_key]

          relation = records
            .except(:limit, :offset, :order)
            .where({_primary_key => res_ids})

          # These are updated as we iterate through the association path; afterwards they will
          # refer to the final resource on the path, i.e. the actual resource to find in the cache.
          # So e.g. if path is [:posts, :comments, :author], then after iteration...
          parent_klass = nil # Comment
          klass = self # Person
          relationship = nil # JSONAPI::Relationship::ToOne for CommentResource.author
          table = nil # people
          assocs_path = [] # [ :posts, :approved_comments, :author ]
          ar_hash = nil # { :posts => { :approved_comments => :author } }

          # For each step on the path, figure out what the actual table name/alias in the join
          # will be, and include the primary key of that table in our list of fields to select
          path.each do |elem|
            relationship = klass._relationships[elem]
            assocs_path << relationship.relation_name(options).to_sym
            # Converts [:a, :b, :c] to Rails-style { :a => { :b => :c }}
            ar_hash = assocs_path.reverse.reduce{|memo, step| { step => memo } }
            # We can't just look up the table name from the resource class, because Arel could
            # have used a table alias if the relation includes a self-reference.
            table = relation.joins(ar_hash).arel.source.right.last.left
            parent_klass = klass
            klass = relationship.resource_klass
            pluck_attrs << table[klass._primary_key]
          end

          # Pre-fill empty hashes for each resource up to the end of the path.
          # This allows us to later distinguish between a preload that returned nothing
          # vs. a preload that never ran.
          prefilling_resources = resources.values
          path.each do |rel_name|
            rel_name = serializer.key_formatter.format(rel_name)
            prefilling_resources.map! do |res|
              res.preloaded_fragments[rel_name] ||= {}
              res.preloaded_fragments[rel_name].values
            end
            prefilling_resources.flatten!(1)
          end

          pluck_attrs << table[klass._cache_field] if klass.caching?
          relation = relation.joins(ar_hash)
          if relationship.is_a?(JSONAPI::Relationship::ToMany)
            # Rails doesn't include order clauses in `joins`, so we have to add that manually here.
            # FIXME Should find a better way to reflect on relationship ordering. :-(
            relation = relation.order(parent_klass._model_class.new.send(assocs_path.last).arel.orders)
          end
          id_rows = pluck_arel_attributes(relation.joins(ar_hash), *pluck_attrs)

          target_resources[klass.name] ||= {}

          if klass.caching?
            sub_cache_ids = id_rows
              .map{|row| row.last(2) }
              .reject{|row| target_resources[klass.name].has_key?(row.first) }
              .uniq
            target_resources[klass.name].merge! CachedResourceFragment.fetch_fragments(
              klass, serializer, context, sub_cache_ids
            )
          else
            sub_res_ids = id_rows
              .map(&:last)
              .reject{|id| target_resources[klass.name].has_key?(id) }
              .uniq
            found = klass.find({klass._primary_key => sub_res_ids}, relevant_options)
            target_resources[klass.name].merge! found.map{|r| [r.id, r] }.to_h
          end

          id_rows.each do |row|
            res = resources[row.first]
            path.each_with_index do |rel_name, index|
              rel_name = serializer.key_formatter.format(rel_name)
              rel_id = row[index+1]
              assoc_rels = res.preloaded_fragments[rel_name]
              if index == path.length - 1
                assoc_rels[rel_id] = target_resources[klass.name].fetch(rel_id)
              else
                res = assoc_rels[rel_id]
              end
            end
          end
        end
      end

      def pluck_arel_attributes(relation, *attrs)
        conn = relation.connection
        quoted_attrs = attrs.map do |attr|
          quoted_table = conn.quote_table_name(attr.relation.table_alias || attr.relation.name)
          quoted_column = conn.quote_column_name(attr.name)
          "#{quoted_table}.#{quoted_column}"
        end
        relation.pluck(*quoted_attrs)
      end
    end
  end
end
