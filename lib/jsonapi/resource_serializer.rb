module JSONAPI
  class ResourceSerializer

    attr_reader :url_generator, :key_formatter, :serialization_options, :primary_class_name

    # initialize
    # Options can include
    # include:
    #     Purpose: determines which objects will be side loaded with the source objects in a linked section
    #     Example: ['comments','author','comments.tags','author.posts']
    # fields:
    #     Purpose: determines which fields are serialized for a resource type. This encompasses both attributes and
    #              relationship ids in the links section for a resource. Fields are global for a resource type.
    #     Example: { people: [:id, :email, :comments], posts: [:id, :title, :author], comments: [:id, :body, :post]}
    # key_formatter: KeyFormatter class to override the default configuration
    # type_formatter: TypeFormatter class to override the default configuration
    # serializer_options: additional options that will be passed to resource meta and links lambdas

    def initialize(primary_resource_klass, options = {})
      @primary_class_name = primary_resource_klass._type
      @fields             = options.fetch(:fields, {})
      @include            = options.fetch(:include, [])
      @include_directives = options[:include_directives]
      @key_formatter      = options.fetch(:key_formatter, JSONAPI.configuration.key_formatter)
      @type_formatter     = options.fetch(:type_formatter, JSONAPI.configuration.type_formatter)
      @url_generator      = generate_link_builder(primary_resource_klass, options)
      @always_include_to_one_linkage_data = options.fetch(:always_include_to_one_linkage_data,
                                                          JSONAPI.configuration.always_include_to_one_linkage_data)
      @always_include_to_many_linkage_data = options.fetch(:always_include_to_many_linkage_data,
                                                           JSONAPI.configuration.always_include_to_many_linkage_data)
      @serialization_options = options.fetch(:serialization_options, {})
    end

    # Converts a single resource, or an array of resources to a hash, conforming to the JSONAPI structure
    def serialize_to_hash(source)
      is_resource_collection = source.respond_to?(:to_ary)

      @included_objects = {}
      @include_directives ||= JSONAPI::IncludeDirectives.new(@include)

      process_primary(source, @include_directives.include_directives)

      included_objects = []
      primary_objects = []
      @included_objects.each_value do |objects|
        objects.each_value do |object|
          if object[:primary]
            primary_objects.push(object[:object_hash])
          else
            included_objects.push(object[:object_hash])
          end
        end
      end

      primary_hash = { data: is_resource_collection ? primary_objects : primary_objects[0] }

      primary_hash[:included] = included_objects if included_objects.size > 0
      primary_hash
    end

    def serialize_to_links_hash(source, requested_relationship)
      if requested_relationship.is_a?(JSONAPI::Relationship::ToOne)
        data = to_one_linkage(source, requested_relationship)
      else
        data = to_many_linkage(source, requested_relationship)
      end

      {
        links: {
          self: self_link(source, requested_relationship),
          related: related_link(source, requested_relationship)
        },
        data: data
      }
    end

    def find_link(query_params)
      url_generator.query_link(query_params)
    end

    def format_key(key)
      @key_formatter.format(key)
    end

    def format_type(type)
      @type_formatter.format(@key_formatter.format(type))
    end

    def format_value(value, format)
      value_formatter = JSONAPI::ValueFormatter.value_formatter_for(format)
      value_formatter.format(value)
    end

    private

    # Process the primary source object(s). This will then serialize associated object recursively based on the
    # requested includes. Fields are controlled fields option for each resource type, such
    # as fields: { people: [:id, :email, :comments], posts: [:id, :title, :author], comments: [:id, :body, :post]}
    # The fields options controls both fields and included links references.
    def process_primary(source, include_directives)
      if source.respond_to?(:to_ary)
        source.each do |resource|
          id = resource.id
          if already_serialized?(resource.class._type, id)
            set_primary(@primary_class_name, id)
          end

          add_included_object(id, object_hash(resource,  include_directives), true)
        end
      else
        return {} if source.nil?

        resource = source
        id = resource.id
        add_included_object(id, object_hash(source, include_directives), true)
      end
    end

    # Returns a serialized hash for the source model
    def object_hash(source, include_directives)
      obj_hash = {}

      id_format = source.class._attribute_options(:id)[:format]
      # protect against ids that were declared as an attribute, but did not have a format set.
      id_format = 'id' if id_format == :default
      obj_hash['id'] = format_value(source.id, id_format)

      obj_hash['type'] = format_type(source.class._type.to_s)

      links = relationship_links(source)
      obj_hash['links'] = links unless links.empty?

      attributes = attribute_hash(source)
      obj_hash['attributes'] = attributes unless attributes.empty?

      relationships = relationship_data(source, include_directives)
      obj_hash['relationships'] = relationships unless relationships.nil? || relationships.empty?

      meta = source.meta(custom_generation_options)
      if meta.is_a?(Hash) && !meta.empty?
        obj_hash['meta'] = meta
      end
      obj_hash
    end

    def requested_fields(klass)
      return if @fields.nil? || @fields.empty?
      t = format_type(klass._type).to_sym
      if @fields[t]
        @fields[t]
      elsif klass.superclass != JSONAPI::Resource
        requested_fields(klass.superclass)
      end
    end

    def attribute_hash(source)
      requested = requested_fields(source.class)
      fields = source.fetchable_fields & source.class._attributes.keys.to_a
      fields = requested & fields unless requested.nil?

      fields.each_with_object({}) do |name, hash|
        format = source.class._attribute_options(name)[:format]
        unless name == :id
          hash[format_key(name)] = format_value(source.public_send(name), format)
        end
      end
    end

    def custom_generation_options
      {
        serializer: self,
        serialization_options: @serialization_options
      }
    end

    def relationship_data(source, include_directives)
      relationships = source.class._relationships
      requested = requested_fields(source.class)
      fields = relationships.keys
      fields = requested & fields unless requested.nil?

      field_set = Set.new(fields)

      included_relationships = source.fetchable_fields & relationships.keys

      data = {}

      relationships.each_with_object(data) do |(name, relationship), hash|
        if included_relationships.include? name
          ia = include_directives[:include_related][name]

          include_linkage = ia && ia[:include]
          include_linked_children = ia && !ia[:include_related].empty?

          if field_set.include?(name)
            hash[format_key(name)] = link_object(source, relationship, include_linkage)
          end

          type = relationship.type

          # If the object has been serialized once it will be in the related objects list,
          # but it's possible all children won't have been captured. So we must still go
          # through the relationships.
          if include_linkage || include_linked_children
            if relationship.is_a?(JSONAPI::Relationship::ToOne)
              resource = source.public_send(name)
              if resource
                id = resource.id
                type = relationship.type_for_source(source)
                relationships_only = already_serialized?(type, id)
                if include_linkage && !relationships_only
                  add_included_object(id, object_hash(resource, ia))
                elsif include_linked_children || relationships_only
                  relationship_data(resource, ia)
                end
              end
            elsif relationship.is_a?(JSONAPI::Relationship::ToMany)
              resources = source.public_send(name)
              resources.each do |resource|
                id = resource.id
                relationships_only = already_serialized?(type, id)
                if include_linkage && !relationships_only
                  add_included_object(id, object_hash(resource, ia))
                elsif include_linked_children || relationships_only
                  relationship_data(resource, ia)
                end
              end
            end
          end
        end
      end
    end

    def relationship_links(source)
      links = {}
      links[:self] = url_generator.self_link(source)

      links
    end

    def already_serialized?(type, id)
      type = format_type(type)
      @included_objects.key?(type) && @included_objects[type].key?(id)
    end

    def self_link(source, relationship)
      url_generator.relationships_self_link(source, relationship)
    end

    def related_link(source, relationship)
      url_generator.relationships_related_link(source, relationship)
    end

    def to_one_linkage(source, relationship)
      linkage = {}
      linkage_id = foreign_key_value(source, relationship)

      if linkage_id
        linkage[:type] = format_type(relationship.type_for_source(source))
        linkage[:id] = linkage_id
      else
        linkage = nil
      end
      linkage
    end

    def to_many_linkage(source, relationship)
      linkage = []
      linkage_types_and_values = foreign_key_types_and_values(source, relationship)

      linkage_types_and_values.each do |type, value|
        linkage.append({type: format_type(type), id: value})
      end
      linkage
    end

    def link_object_to_one(source, relationship, include_linkage)
      include_linkage = include_linkage | @always_include_to_one_linkage_data | relationship.always_include_linkage_data
      link_object_hash = {}
      link_object_hash[:links] = {}
      link_object_hash[:links][:self] = self_link(source, relationship)
      link_object_hash[:links][:related] = related_link(source, relationship)
      link_object_hash[:data] = to_one_linkage(source, relationship) if include_linkage
      link_object_hash
    end

    def link_object_to_many(source, relationship, include_linkage)
      link_object_hash = {}
      link_object_hash[:links] = {}
      link_object_hash[:links][:self] = self_link(source, relationship)
      link_object_hash[:links][:related] = related_link(source, relationship)
      link_object_hash[:data] = to_many_linkage(source, relationship) if include_linkage
      link_object_hash
    end

    def link_object(source, relationship, include_linkage = false)
      if relationship.is_a?(JSONAPI::Relationship::ToOne)
        link_object_to_one(source, relationship, include_linkage)
      elsif relationship.is_a?(JSONAPI::Relationship::ToMany)
        link_object_to_many(source, relationship, include_linkage)
      end
    end

    # Extracts the foreign key value for a to_one relationship.
    def foreign_key_value(source, relationship)
      foreign_key = relationship.foreign_key
      value = source.public_send(foreign_key)
      IdValueFormatter.format(value)
    end

    def foreign_key_types_and_values(source, relationship)
      if relationship.is_a?(JSONAPI::Relationship::ToMany)
        if relationship.polymorphic?
          source._model.public_send(relationship.name).pluck(:type, :id).map do |type, id|
            [type, IdValueFormatter.format(id)]
          end
        else
          source.public_send(relationship.foreign_key).map do |value|
            [relationship.type, IdValueFormatter.format(value)]
          end
        end
      end
    end

    # Sets that an object should be included in the primary document of the response.
    def set_primary(type, id)
      type = format_key(type)
      @included_objects[type][id][:primary] = true
    end

    # Collects the hashes for all objects processed by the serializer
    def add_included_object(id, object_hash, primary = false)
      type = object_hash['type']

      @included_objects[type] = {} unless @included_objects.key?(type)

      if already_serialized?(type, id)
        @included_objects[type][id][:object_hash].merge!(object_hash)
        set_primary(type, id) if primary
      else
        @included_objects[type].store(id, primary: primary, object_hash: object_hash)
      end
    end

    def generate_link_builder(primary_resource_klass, options)
      LinkBuilder.new(
        base_url: options.fetch(:base_url, ''),
        route_formatter: options.fetch(:route_formatter, JSONAPI.configuration.route_formatter),
        primary_resource_klass: primary_resource_klass,
      )
    end
  end
end
