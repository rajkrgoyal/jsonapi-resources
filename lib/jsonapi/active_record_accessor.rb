require 'jsonapi/record_accessor'

module JSONAPI
  class ActiveRecordAccessor < RecordAccessor

    # RecordAccessor methods

    def find_resource(filters, options = {})
      if options[:caching] && options[:caching][:cache_serializer_output]
        find_serialized_with_caching(filters, options[:caching][:serializer], options)
      else
        _resource_klass.resources_for(find_records(filters, options), options[:context])
      end
    end

    def find_resource_by_key(key, options = {})
      if options[:caching] && options[:caching][:cache_serializer_output]
        find_by_key_serialized_with_caching(key, options[:caching][:serializer], options)
      else
        records = find_records({ _resource_klass._primary_key => key }, options.except(:paginator, :sort_criteria))
        model = records.first
        fail JSONAPI::Exceptions::RecordNotFound.new(key) if model.nil?
        _resource_klass.resource_for(model, options[:context])
      end
    end

    def find_resources_by_keys(keys, options = {})
      records = records(options)
      records = apply_includes(records, options)
      records = records.where({ _resource_klass._primary_key => keys })

      _resource_klass.resources_for(records, options[:context])
    end

    def find_count(filters, options = {})
      count_records(filter_records(filters, options))
    end

    def related_resource(resource, relationship_name, options = {})
      relationship = resource.class._relationships[relationship_name.to_sym]

      if relationship.polymorphic?
        associated_model = records_for_relationship(resource, relationship_name, options)
        resource_klass = resource.class.resource_klass_for_model(associated_model) if associated_model
        return resource_klass.new(associated_model, resource.context) if resource_klass && associated_model
      else
        resource_klass = relationship.resource_klass
        if resource_klass
          associated_model = records_for_relationship(resource, relationship_name, options)
          return associated_model ? resource_klass.new(associated_model, resource.context) : nil
        end
      end
    end

    def related_resources(resource, relationship_name, options = {})
      relationship = resource.class._relationships[relationship_name.to_sym]
      relationship_resource_klass = relationship.resource_klass

      if options[:caching] && options[:caching][:cache_serializer_output]
        scope = relationship_resource_klass._record_accessor.records_for_relationship(resource, relationship_name, options)
        relationship_resource_klass._record_accessor.find_serialized_with_caching(scope, options[:caching][:serializer], options)
      else
        records = records_for_relationship(resource, relationship_name, options)
        return records.collect do |record|
          klass = relationship.polymorphic? ? resource.class.resource_klass_for_model(record) : relationship_resource_klass
          klass.new(record, resource.context)
        end
      end
    end

    def count_for_relationship(resource, relationship_name, options = {})
      relationship = resource.class._relationships[relationship_name.to_sym]

      context = resource.context

      relation_name = relationship.relation_name(context: context)
      records = records_for(resource, relation_name)

      resource_klass = relationship.resource_klass

      filters = options.fetch(:filters, {})
      unless filters.nil? || filters.empty?
        records = resource_klass._record_accessor.apply_filters(records, filters, options)
      end

      records.count(:all)
    end

    def foreign_key(resource, relationship_name, options = {})
      relationship = resource.class._relationships[relationship_name.to_sym]

      if relationship.belongs_to?
        resource._model.method(relationship.foreign_key).call
      else
        records = records_for_relationship(resource, relationship_name, options)
        return nil if records.nil?
        records.public_send(relationship.resource_klass._primary_key)
      end
    end

    def foreign_keys(resource, relationship_name, options = {})
      relationship = resource.class._relationships[relationship_name.to_sym]

      records = records_for_relationship(resource, relationship_name, options)
      records.collect do |record|
        record.public_send(relationship.resource_klass._primary_key)
      end
    end

    # protected-ish methods left public for tests and what not

    def find_serialized_with_caching(filters_or_source, serializer, options = {})
      if filters_or_source.is_a?(ActiveRecord::Relation)
        return cached_resources_for(filters_or_source, serializer, options)
      elsif resource_class_based_on_active_record?(_resource_klass)
        records = find_records(filters_or_source, options.except(:include_directives))
        return cached_resources_for(records, serializer, options)
      else
        # :nocov:
        warn('Caching enabled on model not based on ActiveRecord API or similar')
        # :nocov:
      end
    end

    def find_by_key_serialized_with_caching(key, serializer, options = {})
      if resource_class_based_on_active_record?(_resource_klass)
        results = find_serialized_with_caching({ _resource_klass._primary_key => key }, serializer, options)
        result = results.first
        fail JSONAPI::Exceptions::RecordNotFound.new(key) if result.nil?
        return result
      else
        # :nocov:
        warn('Caching enabled on model not based on ActiveRecord API or similar')
        # :nocov:
      end
    end

    def records_for_relationship(resource, relationship_name, options = {})
      relationship = resource.class._relationships[relationship_name.to_sym]

      context = resource.context

      relation_name = relationship.relation_name(context: context)
      records = records_for(resource, relation_name)

      resource_klass = relationship.resource_klass

      filters = options.fetch(:filters, {})
      unless filters.nil? || filters.empty?
        records = resource_klass._record_accessor.apply_filters(records, filters, options)
      end

      sort_criteria = options.fetch(:sort_criteria, {})
      order_options = relationship.resource_klass.construct_order_options(sort_criteria)
      records = apply_sort(records, order_options, context)

      paginator = options[:paginator]
      if paginator
        records = apply_pagination(records, paginator, order_options)
      end

      records
    end

    # Implement self.records on the resource if you want to customize the relation for
    # finder methods (find, find_by_key, find_serialized_with_caching)
    def records(_options = {})
      if defined?(_resource_klass.records)
        _resource_klass.records(_options)
      else
        _resource_klass._model_class.all
      end
    end

    # Implement records_for on the resource to customize how the associated records
    # are fetched for a model. Particularly helpful for authorization.
    def records_for(resource, relation_name)
      if resource.respond_to?(:records_for)
        return resource.records_for(relation_name)
      end

      relationship = resource.class._relationships[relation_name]

      if relationship.is_a?(JSONAPI::Relationship::ToMany)
        if resource.respond_to?(:"records_for_#{relation_name}")
          return resource.method(:"records_for_#{relation_name}").call
        end
      else
        if resource.respond_to?(:"record_for_#{relation_name}")
          return resource.method(:"record_for_#{relation_name}").call
        end
      end

      resource._model.public_send(relation_name)
    end

    def apply_includes(records, options = {})
      include_directives = options[:include_directives]
      if include_directives
        model_includes = resolve_relationship_names_to_relations(_resource_klass, include_directives.model_includes, options)
        records = records.includes(model_includes)
      end

      records
    end

    def apply_pagination(records, paginator, order_options)
      records = paginator.apply(records, order_options) if paginator
      records
    end

    def apply_sort(records, order_options, context = {})
      if defined?(_resource_klass.apply_sort)
        _resource_klass.apply_sort(records, order_options, context)
      else
        if order_options.any?
          order_options.each_pair do |field, direction|
            if field.to_s.include?(".")
              *model_names, column_name = field.split(".")

              associations = _lookup_association_chain([records.model.to_s, *model_names])
              joins_query = _build_joins([records.model, *associations])

              # _sorting is appended to avoid name clashes with manual joins eg. overridden filters
              order_by_query = "#{associations.last.name}_sorting.#{column_name} #{direction}"
              records = records.joins(joins_query).order(order_by_query)
            else
              records = records.order(field => direction)
            end
          end
        end

        records
      end
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
      strategy = _resource_klass._allowed_filters.fetch(filter.to_sym, Hash.new)[:apply]

      if strategy
        if strategy.is_a?(Symbol) || strategy.is_a?(String)
          _resource_klass.send(strategy, records, value, options)
        else
          strategy.call(records, value, options)
        end
      else
        records.where(filter => value)
      end
    end

    # Assumes ActiveRecord's counting. Override if you need a different counting method
    def count_records(records)
      records.count(:all)
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

    def apply_filters(records, filters, options = {})
      required_includes = []

      if filters
        filters.each do |filter, value|
          if _resource_klass._relationships.include?(filter)
            if _resource_klass._relationships[filter].belongs_to?
              records = apply_filter(records, _resource_klass._relationships[filter].foreign_key, value, options)
            else
              required_includes.push(filter.to_s)
              records = apply_filter(records, "#{_resource_klass._relationships[filter].table_name}.#{_resource_klass._relationships[filter].primary_key}", value, options)
            end
          else
            records = apply_filter(records, filter, value, options)
          end
        end
      end

      if required_includes.any?
        records = apply_includes(records, options.merge(include_directives: IncludeDirectives.new(_resource_klass, required_includes, force_eager_load: true)))
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

    def cached_resources_for(records, serializer, options)
      if _resource_klass.caching?
        t = _resource_klass._model_class.arel_table
        cache_ids = pluck_arel_attributes(records, t[_resource_klass._primary_key], t[_resource_klass._cache_field])
        resources = CachedResourceFragment.fetch_fragments(_resource_klass, serializer, options[:context], cache_ids)
      else
        resources = _resource_klass.resources_for(records, options[:context]).map { |r| [r.id, r] }.to_h
      end

      result = resources.values # Don't add preloaded fragments to top-level return value

      if options[:include_directives]
        resource_pile = { _resource_klass.name => resources }
        options[:include_directives].all_paths.each do |path|
          # Note that `all_paths` returns shorter paths first, so e.g. the partial fragments for
          # posts.comments will exist before we start working with posts.comments.author
          preload_included_fragments(_resource_klass, resource_pile, path, serializer, options)
        end
      end

      result
    end

    def find_records(filters, options = {})
      if defined?(_resource_klass.find_records)
        ActiveSupport::Deprecation.warn "In #{_resource_klass.name} you overrode `find_records`. "\
                                        "`find_records` has been deprecated in favor of using `apply` "\
                                        "and `verify` callables on the filter."

        _resource_klass.find_records(filters, options)
      else
        context = options[:context]

        records = filter_records(filters, options)

        sort_criteria = options.fetch(:sort_criteria) { [] }
        order_options = _resource_klass.construct_order_options(sort_criteria)
        records = sort_records(records, order_options, context)

        records = apply_pagination(records, options[:paginator], order_options)

        records
      end
    end

    def preload_included_fragments(src_res_class, resource_pile, path, serializer, options)
      src_resources = resource_pile[src_res_class.name]
      return if src_resources.nil? || src_resources.empty?

      rel_name = path.first
      relationship = src_res_class._relationships[rel_name]
      if relationship.polymorphic
        # FIXME Preloading through a polymorphic belongs_to association is not implemented.
        # For now, in this case, ResourceSerializer will have to do the fetch itself, without
        # using either the cache or eager-loading.
        return
      end

      tgt_res_class = relationship.resource_klass
      unless resource_class_based_on_active_record?(tgt_res_class)
        # Can't preload relationships from non-AR resources, this association will be filled
        # in on-demand later by ResourceSerializer.
        return
      end

      # Assume for longer paths that the intermediate fragments have already been preloaded
      if path.length > 1
        preload_included_fragments(tgt_res_class, resource_pile, path.drop(1), serializer, options)
        return
      end

      record_source = src_res_class._model_class
                                      .where({ src_res_class._primary_key => src_resources.keys })
                                      .joins(relationship.relation_name(options).to_sym)

      if relationship.is_a?(JSONAPI::Relationship::ToMany)
        # Rails doesn't include order clauses in `joins`, so we have to add that manually here.
        # FIXME Should find a better way to reflect on relationship ordering. :-(
        fake_model_instance = src_res_class._model_class.new
        record_source = record_source.order(fake_model_instance.send(rel_name).arel.orders)
      end

      # Pre-fill empty fragment hashes.
      # This allows us to later distinguish between a preload that returned nothing
      # vs. a preload that never ran.
      serialized_rel_name = serializer.key_formatter.format(rel_name)
      src_resources.each do |key, res|
        res.preloaded_fragments[serialized_rel_name] ||= {}
      end

      # We can't just look up the table name from the target class, because Arel could
      # have used a table alias if the relation is a self-reference.
      join_node = record_source.arel.source.right.reverse.find do |arel_node|
        arel_node.is_a?(Arel::Nodes::InnerJoin)
      end
      tgt_table = join_node.left

      # Resource class may restrict current user to a subset of available records
      if tgt_res_class.respond_to?(:records)
        valid_tgts_rel = tgt_res_class.records(options)
        valid_tgts_rel = valid_tgts_rel.all if valid_tgts_rel.respond_to?(:all)
        conn = valid_tgts_rel.connection
        tgt_attr = tgt_table[tgt_res_class._primary_key]

        # Alter a normal AR query to select only the primary key instead of all columns.
        # Sadly doing direct string manipulation of query here, cannot use ARel for this due to
        # bind values being stripped from AR::Relation#arel in Rails >= 4.2, see
        # https://github.com/rails/arel/issues/363
        valid_tgts_query = valid_tgts_rel.to_sql.sub('*', conn.quote_column_name(tgt_attr.name))
        valid_tgts_cond = "#{quote_arel_attribute(conn, tgt_attr)} IN (#{valid_tgts_query})"

        record_source = record_source.where(valid_tgts_cond)
      end

      pluck_attrs = [
        src_res_class._model_class.arel_table[src_res_class._primary_key],
        tgt_table[tgt_res_class._primary_key]
      ]
      pluck_attrs << tgt_table[tgt_res_class._cache_field] if tgt_res_class.caching?

      id_rows = pluck_arel_attributes(record_source, *pluck_attrs)

      target_resources = resource_pile[tgt_res_class.name] ||= {}

      if tgt_res_class.caching?
        sub_cache_ids = id_rows.map{ |row| row.last(2) }.uniq.reject{|p| target_resources.has_key?(p[0]) }
        target_resources.merge! CachedResourceFragment.fetch_fragments(
            tgt_res_class, serializer, options[:context], sub_cache_ids
        )
      else
        sub_res_ids = id_rows.map(&:last).uniq - target_resources.keys
        recs = tgt_res_class.find({ tgt_res_class._primary_key => sub_res_ids }, context: options[:context])
        target_resources.merge!(recs.map{ |r| [r.id, r] }.to_h)
      end

      id_rows.each do |row|
        src_id, tgt_id = row[0], row[1]
        src_res = src_resources[src_id]
        next unless src_res
        fragment = target_resources[tgt_id]
        next unless fragment
        src_res.preloaded_fragments[serialized_rel_name][tgt_id] = fragment 
      end
    end

    def pluck_arel_attributes(relation, *attrs)
      conn = relation.connection
      quoted_attrs = attrs.map{|attr| quote_arel_attribute(conn, attr) }
      relation.pluck(*quoted_attrs)
    end

    def quote_arel_attribute(connection, attr)
      quoted_table = connection.quote_table_name(attr.relation.table_alias || attr.relation.name)
      quoted_column = connection.quote_column_name(attr.name)
      "#{quoted_table}.#{quoted_column}"
    end

    def resource_class_based_on_active_record?(klass)
      model_class = klass._model_class
      model_class.respond_to?(:all) && model_class.respond_to?(:arel_table)
    end
  end
end
