require File.expand_path('../../../test_helper', __FILE__)

class JSONAPIRequestTest < ActiveSupport::TestCase
  class CatResource < JSONAPI::Resource
    attribute :name
    attribute :breed

    belongs_to :mother, class_name: 'Cat'
    has_one :father, class_name: 'Cat'

    filters :name

    def self.sortable_fields(context)
      super(context) << :"mother.name"
    end
  end

  def test_parse_includes_underscored
    setup_request(
      {
        controller: 'expense_entries',
        action: 'index',
        include: 'iso_currency'
      },
      {
        key_formatter: JSONAPI::Formatter.formatter_for(:underscored_key)
      }
    )

    operations = @request.operations
    assert_equal(1, operations.size)
    assert_equal(:find, operations.first.operation_type)
    assert_equal(
      { include_related: { iso_currency: { include: true, include_related: {} }}},
      operations.first.options[:include_directives].include_directives
    )
  end

  def test_parse_dasherized_with_dasherized_include
    setup_request(
      {
        controller: 'expense_entries',
        action: 'index',
        include: 'iso-currency'
      },
      {
        key_formatter: JSONAPI::Formatter.formatter_for(:dasherized_key)
      }
    )

    operations = @request.operations
    assert_equal(1, operations.size)
    assert_equal(:find, operations.first.operation_type)
    assert_equal(
      { include_related: { iso_currency: { include: true, include_related: {} }}},
      operations.first.options[:include_directives].include_directives
    )
  end

  def test_parse_dasherized_with_underscored_include
    setup_request(
      {
        controller: 'expense_entries',
        action: 'index',
        include: 'iso_currency'
      },
      {
        key_formatter: JSONAPI::Formatter.formatter_for(:dasherized_key)
      }
    )

    assert_raises(JSONAPI::Exceptions::InvalidInclude) do
      @request.operations
    end
  end

  def test_parse_fields_underscored
    setup_request(
      {
        controller: 'expense_entries',
        action: 'index',
        fields: {expense_entries: 'iso_currency'}
      },
      {
        key_formatter: JSONAPI::Formatter.formatter_for(:underscored_key)
      }
    )

    operations = @request.operations
    assert_equal(1, operations.size)
    assert_equal(:find, operations.first.operation_type)
    assert_equal({expense_entries: [:iso_currency]}, operations.first.options[:fields])
  end

  def test_parse_dasherized_with_dasherized_fields
    setup_request(
      {
        controller: 'expense_entries',
        action: 'index',
        fields: {
          'expense-entries' => 'iso-currency'
        }
      },
      {
        key_formatter: JSONAPI::Formatter.formatter_for(:dasherized_key)
      }
    )


    operations = @request.operations
    assert_equal(1, operations.size)
    assert_equal(:find, operations.first.operation_type)
    assert_equal({expense_entries: [:iso_currency]}, operations.first.options[:fields])
  end

  def test_parse_dasherized_with_underscored_fields
    setup_request(
      {
        controller: 'expense_entries',
        action: 'index',
        fields: {
          'expense-entries' => 'iso_currency'
        }
      },
      {
        key_formatter: JSONAPI::Formatter.formatter_for(:dasherized_key)
      }
    )

    assert_raises(JSONAPI::Exceptions::InvalidField) do
      @request.operations
    end
  end

  def test_parse_dasherized_with_underscored_resource
    setup_request(
      {
        controller: 'expense_entries',
        action: 'index',
        fields: {
          'expense_entries' => 'iso-currency'
        }
      },
      {
        key_formatter: JSONAPI::Formatter.formatter_for(:dasherized_key)
      }
    )

    assert_raises(JSONAPI::Exceptions::InvalidResource) do
      @request.operations
    end
  end

  def test_parse_filters_with_valid_filters
    setup_request(filter: {name: 'Whiskers'})
    assert_equal(@request.filters[:name], 'Whiskers')
  end

  def test_parse_filters_with_non_valid_filter
    setup_request(filter: {breed: 'Whiskers'}) # breed is not a set filter
    assert_raises(JSONAPI::Exceptions::FilterNotAllowed) do
      @request.filters
    end
  end

  def test_parse_filters_with_no_filters
    setup_request
    assert_equal(@request.filters, {})
  end

  def test_parse_filters_with_invalid_filters_param
    setup_request(filter: 'noeach') # String does not implement #each
    assert_raises(JSONAPI::Exceptions::InvalidFiltersSyntax) do
      @request.filters
    end
  end

  def test_parse_sort_with_valid_sorts
    setup_request(sort: '-name')
    assert_equal(@request.filters, {})
    assert_equal(@request.sort_criteria, [{:field=>"name", :direction=>:desc}])
  end

  def test_parse_sort_with_relationships
    setup_request(sort: '-mother.name')
    assert_equal(@request.filters, {})
    assert_equal(@request.sort_criteria, [{:field=>"mother.name", :direction=>:desc}])
  end

  private

  def setup_request(params = {}, options = {})
    @request = JSONAPI::RequestParser.new(ActionController::Parameters.new(params), options)
    @request.resource_klass = CatResource unless params.has_key?(:controller)
  end
end
