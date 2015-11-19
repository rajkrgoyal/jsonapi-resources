require 'jsonapi/callbacks'

module JSONAPI
  class Resource
    include Callbacks

    @@resource_types = {}

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

    def fetchable_fields
      self.class.fetchable_fields(context)
    end

    # Override this on a resource to customize how the associated records
    # are fetched for a model. Particularly helpful for authorization.
    def records_for(relation_name)
      _model.public_send relation_name
    end

    def model_error_messages
      _model.errors.messages
    end

    # Override this to return resource level meta data
    # must return a hash, and if the hash is empty the meta section will not be serialized with the resource
    # meta keys will be not be formatted with the key formatter for the serializer by default. They can however use the
    # serializer's format_key and format_value methods if desired
    # the _options hash will contain the serializer and the serialization_options
    def meta(_options)
      {}
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
    def _save
      unless @model.valid?
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
      @model.destroy

      :completed
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
      def inherited(base)
        base.abstract(false)
        base.immutable(false)
        base._attributes = (_attributes || {}).dup
        base._relationships = (_relationships || {}).dup
        base._allowed_filters = (_allowed_filters || Set.new).dup

        base._type = base.name.demodulize.sub(/Resource$/, '')

        base.attribute :id, format: :id

        check_reserved_resource_name(base._type, base.name)
      end

      def resource_for(resource_path)
        unless @@resource_types.key? resource_path
          klass_name = "#{resource_path.to_s.underscore.singularize}_resource".camelize
          klass = (klass_name.safe_constantize or
            fail NameError,
                 "JSONAPI: Could not find resource '#{resource_path}'. (Class #{klass_name} not found)")
          normalized_path = resource_path.rpartition('/').first
          normalized_model = klass._model_name.to_s.gsub(/\A::/, '')
          @@resource_types[resource_path] = {
            resource: klass,
            path: normalized_path,
            model: normalized_model,
          }
        end
        @@resource_types[resource_path][:resource]
      end

      def resource_for_model_path(model, path)
        normalized_model = model.class.to_s.gsub(/\A::/, '')
        normalized_path = path.gsub(/\/\z/, '')
        resource = @@resource_types.find { |_, h|
          h[:path] == normalized_path && h[:model] == normalized_model
        }
        if resource
          resource.last[:resource]
        else
          #:nocov:#
          fail NameError,
               "JSONAPI: Could not find resource for model '#{path}#{normalized_model}'"
          #:nocov:#
        end
      end

      attr_accessor :_attributes, :_relationships, :_allowed_filters, :_type, :_paginator

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
          @model.public_send(attr)
        end unless method_defined?(attr)

        define_method "#{attr}=" do |value|
          @model.public_send "#{attr}=", value
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

      def has_many(*attrs)
        _add_relationship(Relationship::ToMany, *attrs)
      end

      def model_name(model)
        @_model_name = model.to_sym
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

      # TODO: remove this after the createable_fields and updateable_fields are phased out
      # :nocov:
      def method_missing(method, *args)
        if method.to_s.match /createable_fields/
          ActiveSupport::Deprecation.warn('`createable_fields` is deprecated, please use `creatable_fields` instead')
          creatable_fields(*args)
        elsif method.to_s.match /updateable_fields/
          ActiveSupport::Deprecation.warn('`updateable_fields` is deprecated, please use `updatable_fields` instead')
          updatable_fields(*args)
        else
          super
        end
      end
      # :nocov:

      # Override in your resource to filter the fetchable keys
      def fetchable_fields(_context = nil)
        fields
      end

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

      def apply_sort(records, order_options)
        if order_options.any?
          records.order(order_options)
        else
          records
        end
      end

      def apply_filter(records, filter, value, _options = {})
        records.where(filter => value)
      end

      def apply_filters(records, filters, options = {})
        required_includes = []

        if filters
          filters.each do |filter, value|
            if _relationships.include?(filter)
              if _relationships[filter].is_a?(JSONAPI::Relationship::ToMany)
                required_includes.push(filter.to_s)
                records = apply_filter(records, "#{filter}.#{_relationships[filter].primary_key}", value, options)
              else
                records = apply_filter(records, "#{_relationships[filter].foreign_key}", value, options)
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

      def sort_records(records, order_options)
        apply_sort(records, order_options)
      end

      def find_count(filters, options = {})
        filter_records(filters, options).count(:all)
      end

      # Override this method if you have more complex requirements than this basic find method provides
      def find(filters, options = {})
        context = options[:context]

        records = filter_records(filters, options)

        sort_criteria = options.fetch(:sort_criteria) { [] }
        order_options = construct_order_options(sort_criteria)
        records = sort_records(records, order_options)

        records = apply_pagination(records, options[:paginator], order_options)

        resources = []
        records.each do |model|
          resources.push resource_for_model_path(model, self.module_path).new(model, context)
        end

        resources
      end

      def find_by_key(key, options = {})
        context = options[:context]
        records = records(options)
        records = apply_includes(records, options)
        model = records.where({_primary_key => key}).first
        fail JSONAPI::Exceptions::RecordNotFound.new(key) if model.nil?
        resource_for_model_path(model, self.module_path).new(model, context)
      end

      # Override this method if you want to customize the relation for
      # finder methods (find, find_by_key)
      def records(_options = {})
        _model_class
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
        filter_values += CSV.parse_line(raw) unless raw.nil? || raw.empty?

        if is_filter_relationship?(filter)
          verify_relationship_filter(filter, filter_values, context)
        else
          verify_custom_filter(filter, filter_values, context)
        end
      end

      def key_type(key_type)
        @_resource_key_type = key_type
      end

      def resource_key_type
        @_resource_key_type || JSONAPI.configuration.resource_key_type
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

      # override to allow for custom filters
      def verify_custom_filter(filter, value, _context = nil)
        [filter, value]
      end

      # override to allow for custom relationship logic, such as uuids, multiple keys or permission checks on keys
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
        @_model_name ||= name.demodulize.sub(/Resource$/, '')
      end

      def _primary_key
        @_primary_key ||= _model_class.respond_to?(:primary_key) ? _model_class.primary_key : :id
      end

      def _as_parent_key
        @_as_parent_key ||= "#{_type.to_s.singularize}_id"
      end

      def _allowed_filters
        !@_allowed_filters.nil? ? @_allowed_filters : { id: {} }
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

      def _model_class
        return nil if _abstract

        return @model if @model
        @model = _model_name.to_s.safe_constantize
        warn "[MODEL NOT FOUND] Model could not be found for #{self.name}. If this a base Resource declare it as abstract." if @model.nil?
        @model
      end

      def _allowed_filter?(filter)
        !_allowed_filters[filter].nil?
      end

      def module_path
        name =~ /::[^:]+\Z/ ? ($`.freeze.gsub('::', '/') + '/').underscore : ''
      end

      def construct_order_options(sort_params)
        return {} unless sort_params

        sort_params.each_with_object({}) do |sort, order_hash|
          field = sort[:field] == 'id' ? _primary_key : sort[:field]
          order_hash[field] = sort[:direction]
        end
      end

      private

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
          warn "[NAME COLLISION] `#{name}` is a reserved key in #{@@resource_types[_type]}."
        end
      end

      def check_reserved_relationship_name(name)
        if [:id, :ids, :type, :types].include?(name.to_sym)
          warn "[NAME COLLISION] `#{name}` is a reserved relationship name in #{@@resource_types[_type]}."
        end
      end

      def _add_relationship(klass, *attrs)
        options = attrs.extract_options!
        options[:module_path] = module_path

        attrs.each do |attr|
          check_reserved_relationship_name(attr)

          # Initialize from an ActiveRecord model's properties
          if _model_class && _model_class.ancestors.collect{|ancestor| ancestor.name}.include?('ActiveRecord::Base')
            model_association = _model_class.reflect_on_association(attr)
            if model_association
              options[:class_name] ||= model_association.class_name
            end
          end

          @_relationships[attr] = relationship = klass.new(attr, options)

          associated_records_method_name = case relationship
                                           when JSONAPI::Relationship::ToOne then "record_for_#{attr}"
                                           when JSONAPI::Relationship::ToMany then "records_for_#{attr}"
                                           end

          foreign_key = relationship.foreign_key

          define_method "#{foreign_key}=" do |value|
            @model.method("#{foreign_key}=").call(value)
          end unless method_defined?("#{foreign_key}=")

          define_method associated_records_method_name do
            relation_name = relationship.relation_name(context: @context)
            records_for(relation_name)
          end unless method_defined?(associated_records_method_name)

          if relationship.is_a?(JSONAPI::Relationship::ToOne)
            if relationship.belongs_to?
              define_method foreign_key do
                @model.method(foreign_key).call
              end unless method_defined?(foreign_key)

              define_method attr do |options = {}|
                if relationship.polymorphic?
                  associated_model = public_send(associated_records_method_name)
                  resource_klass = self.class.resource_for_model_path(associated_model, self.class.module_path) if associated_model
                  return resource_klass.new(associated_model, @context) if resource_klass
                else
                  resource_klass = relationship.resource_klass
                  if resource_klass
                    associated_model = public_send(associated_records_method_name)
                    return associated_model ? resource_klass.new(associated_model, @context) : nil
                  end
                end
              end unless method_defined?(attr)
            else
              define_method foreign_key do
                record = public_send(associated_records_method_name)
                return nil if record.nil?
                record.public_send(relationship.resource_klass._primary_key)
              end unless method_defined?(foreign_key)

              define_method attr do |options = {}|
                resource_klass = relationship.resource_klass
                if resource_klass
                  associated_model = public_send(associated_records_method_name)
                  return associated_model ? resource_klass.new(associated_model, @context) : nil
                end
              end unless method_defined?(attr)
            end
          elsif relationship.is_a?(JSONAPI::Relationship::ToMany)
            define_method foreign_key do
              records = public_send(associated_records_method_name)
              return records.collect do |record|
                record.public_send(relationship.resource_klass._primary_key)
              end
            end unless method_defined?(foreign_key)
            define_method attr do |options = {}|
              resource_klass = relationship.resource_klass
              records = public_send(associated_records_method_name)

              filters = options.fetch(:filters, {})
              unless filters.nil? || filters.empty?
                records = resource_klass.apply_filters(records, filters, options)
              end

              sort_criteria =  options.fetch(:sort_criteria, {})
              unless sort_criteria.nil? || sort_criteria.empty?
                order_options = relationship.resource_klass.construct_order_options(sort_criteria)
                records = resource_klass.apply_sort(records, order_options)
              end

              paginator = options[:paginator]
              if paginator
                records = resource_klass.apply_pagination(records, paginator, order_options)
              end

              return records.collect do |record|
                resource_klass = self.class.resource_for_model_path(record, self.class.module_path)
                resource_klass.new(record, @context)
              end
            end unless method_defined?(attr)
          end
        end
      end
    end
  end
end
