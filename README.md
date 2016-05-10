# JSONAPI::Resources [![Gem Version](https://badge.fury.io/rb/jsonapi-resources.svg)](https://badge.fury.io/rb/jsonapi-resources) [![Build Status](https://secure.travis-ci.org/cerebris/jsonapi-resources.svg?branch=master)](http://travis-ci.org/cerebris/jsonapi-resources) [![Code Climate](https://codeclimate.com/github/cerebris/jsonapi-resources/badges/gpa.svg)](https://codeclimate.com/github/cerebris/jsonapi-resources)

[![Join the chat at https://gitter.im/cerebris/jsonapi-resources](https://badges.gitter.im/Join%20Chat.svg)](https://gitter.im/cerebris/jsonapi-resources?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge)

`JSONAPI::Resources`, or "JR", provides a framework for developing a server that complies with the
[JSON API](http://jsonapi.org/) specification.

Like JSON API itself, JR's design is focused on the resources served by an API. JR needs little more than a definition
of your resources, including their attributes and relationships, to make your server compliant with JSON API.

JR is designed to work with Rails 4.0+, and provides custom routes, controllers, and serializers. JR's resources may be
backed by ActiveRecord models or by custom objects.

## Table of Contents

* [Demo App] (#demo-app)
* [Client Libraries] (#client-libraries)
* [Installation] (#installation)
* [Usage] (#usage)
  * [Resources] (#resources)
    * [JSONAPI::Resource] (#jsonapiresource)
    * [Context] (#context)
    * [Attributes] (#attributes)
    * [Primary Key] (#primary-key)
    * [Model Name] (#model-name)
    * [Model Hints] (#model-hints)
    * [Relationships] (#relationships)
    * [Filters] (#filters)
    * [Pagination] (#pagination)
    * [Included relationships (side-loading resources)] (#included-relationships-side-loading-resources)
    * [Resource meta] (#resource-meta)
    * [Custom Links] (#custom-links)
    * [Callbacks] (#callbacks)
  * [Controllers] (#controllers)
    * [Namespaces] (#namespaces)
    * [Error Codes] (#error-codes)
    * [Handling Exceptions] (#handling-exceptions)
    * [Action Callbacks] (#action-callbacks)
  * [Operation Processors] (#operation-processors)
  * [Serializer] (#serializer)
    * [Serializer options] (#serializer-options)
    * [Formatting] (#formatting)
    * [Key Format] (#key-format)
  * [Routing] (#routing)
    * [Nested Routes] (#nested-routes)
  * [Resource Caching] (#resource-caching)
    * [Caching Caveats] (#caching-caveats)
* [Configuration] (#configuration)
* [Contributing] (#contributing)
* [License] (#license)

## Demo App

We have a simple demo app, called [Peeps](https://github.com/cerebris/peeps), available to show how JR is used.

## Client Libraries

JSON API maintains a (non-verified) listing of [client libraries](http://jsonapi.org/implementations/#client-libraries)
which *should* be compatible with JSON API compliant server implementations such as JR.

## Installation

Add JR to your application's `Gemfile`:

    gem 'jsonapi-resources'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install jsonapi-resources

## Usage

### Resources

Resources define the public interface to your API. A resource defines which attributes are exposed, as well as
relationships to other resources.

Resource definitions should by convention be placed in a directory under app named resources, `app/resources`. The file name should be the single underscored name of the model that backs the resource with `_resource.rb` appended. For example,
a `Contact` model's resource should have a class named `ContactResource` defined in a file named `contact_resource.rb`.

#### JSONAPI::Resource

Resources must be derived from `JSONAPI::Resource`, or a class that is itself derived from `JSONAPI::Resource`.

For example:

```ruby
class ContactResource < JSONAPI::Resource
end
```

A jsonapi-resource generator is available
```
rails generate jsonapi:resource contact
```

##### Abstract Resources

Resources that are not backed by a model (purely used as base classes for other resources) should be declared as
abstract.

Because abstract resources do not expect to be backed by a model, they won't attempt to discover the model class
or any of its relationships.

```ruby
class BaseResource < JSONAPI::Resource
  abstract

  has_one :creator
end

class ContactResource < BaseResource
end
```

##### Immutable Resources

Resources that are immutable should be declared as such with the `immutable` method. Immutable resources will only
generate routes for `index`, `show` and `show_relationship`.

###### Immutable for Readonly

Some resources are read-only and are not to be modified through the API. Declaring a resource as immutable prevents
creation of routes that allow modification of the resource.

###### Immutable Heterogeneous Collections

Immutable resources can be used as the basis for a heterogeneous collection. Resources in heterogeneous collections can
still be mutated through their own type-specific endpoints.

```ruby
class VehicleResource < JSONAPI::Resource
  immutable

  has_one :owner
  attributes :make, :model, :serial_number
end

class CarResource < VehicleResource
  attributes :drive_layout
  has_one :driver
end

class BoatResource < VehicleResource
  attributes :length_at_water_line
  has_one :captain
end

# routes
  jsonapi_resources :vehicles
  jsonapi_resources :cars
  jsonapi_resources :boats

```

In the above example vehicles are immutable. A call to `/vehicles` or `/vehicles/1` will return vehicles with types
of either `car` or `boat`. But calls to PUT or POST a `car` must be made to `/cars`. The rails models backing the above
code use Single Table Inheritance.

#### Context

Sometimes you will want to access things such as the current logged in user (and other state only available within your controllers) from within your resource classes. To make this state available to a resource class you need to put it into the context hash - this can be done via a `context` method on one of your controllers or across all controllers using ApplicationController.

For example:

```ruby
class ApplicationController < JSONAPI::ResourceController
  def context
    {current_user: current_user}
  end
end

# Specific resource controllers derive from ApplicationController
# and share its context
class PeopleController < ApplicationController

end

# Assuming you don't permit user_id (so the client won't assign a wrong user to own the object)
# you can ensure the current user is assigned the record by using the controller's context hash.
class PeopleResource < JSONAPI::Resource
  before_save do
    @model.user_id = context[:current_user].id if @model.new_record?
  end
end
```

You can put things that affect serialization and resource configuration into the context.

#### Attributes

Any of a resource's attributes that are accessible must be explicitly declared. Single attributes can be declared using
the `attribute` method, and multiple attributes can be declared with the `attributes` method on the resource class.

For example:

```ruby
class ContactResource < JSONAPI::Resource
  attribute :name_first
  attributes :name_last, :email, :twitter
end
```

This resource has 4 defined attributes: `name_first`, `name_last`, `email`, `twitter`, as well as the automatically
defined attributes `id` and `type`. By default these attributes must exist on the model that is handled by the resource.

A resource object wraps a Ruby object, usually an `ActiveModel` record, which is available as the `@model` variable.
This allows a resource's methods to access the underlying model.

For example, a computed attribute for `full_name` could be defined as such:

```ruby
class ContactResource < JSONAPI::Resource
  attributes :name_first, :name_last, :email, :twitter
  attribute :full_name

  def full_name
    "#{@model.name_first}, #{@model.name_last}"
  end
end
```

##### Attribute Delegation

Normally resource attributes map to an attribute on the model of the same name. Using the `delegate` option allows a resource
attribute to map to a differently named model attribute. For example:

```ruby
class ContactResource < JSONAPI::Resource
  attribute :name_first, delegate: :first_name
  attribute :name_last, delegate: :last_name
end
```

##### Fetchable Attributes

By default all attributes are assumed to be fetchable. The list of fetchable attributes can be filtered by overriding
the `fetchable_fields` method.

Here's an example that prevents guest users from seeing the `email` field:

```ruby
class AuthorResource < JSONAPI::Resource
  attributes :name, :email
  model_name 'Person'
  has_many :posts

  def fetchable_fields
    if (context[:current_user].guest)
      super - [:email]
    else
      super
    end
  end
end
```

Context flows through from the controller to the resource and can be used to control the attributes based on the
current user (or other value).

##### Creatable and Updatable Attributes

By default all attributes are assumed to be updatable and creatable. To prevent some attributes from being accepted by
the `update` or `create` methods, override the `self.updatable_fields` and `self.creatable_fields` methods on a resource.

This example prevents `full_name` from being set:

```ruby
class ContactResource < JSONAPI::Resource
  attributes :name_first, :name_last, :full_name

  def full_name
    "#{@model.name_first}, #{@model.name_last}"
  end

  def self.updatable_fields(context)
    super - [:full_name]
  end

  def self.creatable_fields(context)
    super - [:full_name]
  end
end
```

The `context` is not by default used by the `ResourceController`, but may be used if you override the controller methods.
By using the context you have the option to determine the creatable and updatable fields based on the user.

##### Sortable Attributes

JR supports [sorting primary resources by multiple sort criteria](http://jsonapi.org/format/#fetching-sorting).

By default all attributes are assumed to be sortable. To prevent some attributes from being sortable, override the
`self.sortable_fields` method on a resource.

Here's an example that prevents sorting by post's `body`:

```ruby
class PostResource < JSONAPI::Resource
  attributes :title, :body

  def self.sortable_fields(context)
    super(context) - [:body]
  end
end
```

JR also supports sorting primary resources by fields on relationships.

Here's an example of sorting books by the author name:

```ruby
class Book < ActiveRecord::Base
    belongs_to :author
end

class Author < ActiveRecord::Base
    has_many :books
end

class BookResource < JSONAPI::Resource
  attributes :title, :body

  def self.sortable_fields(context)
    super(context) << :"author.name"
   end
end
```
The request will look something like:
```
GET /books?include=author&sort=author.name
```

##### Attribute Formatting

Attributes can have a `Format`. By default all attributes use the default formatter. If an attribute has the `format`
option set the system will attempt to find a formatter based on this name. In the following example the `last_login_time`
will be returned formatted to a certain time zone:

```ruby
class PersonResource < JSONAPI::Resource
  attributes :name, :email
  attribute :last_login_time, format: :date_with_timezone
end
```

The system will lookup a value formatter named `DateWithTimezoneValueFormatter` and will use this when serializing and
updating the attribute. See the [Value Formatters](#value-formatters) section for more details.

##### Flattening a Rails relationship

It is possible to flatten Rails relationships into attributes by using getters and setters. This can become handy if a relation needs to be created alongside the creation of the main object which can be the case if there is a bi-directional presence validation. For example:

```ruby
# Given Models
class Person < ActiveRecord::Base
  has_many :spoken_languages
  validates :name, :email, :spoken_languages, presence: true
end

class SpokenLanguage < ActiveRecord::Base
  belongs_to :person, inverse_of: :spoken_languages
  validates :person, :language_code, presence: true
end

# Resource with getters and setter
class PersonResource < JSONAPI::Resource
  attributes :name, :email, :spoken_languages

  # Getter
  def spoken_languages
    @model.spoken_languages.pluck(:language_code)
  end

  # Setter (because spoken_languages needed for creation)
  def spoken_languages=(new_spoken_language_codes)
    @model.spoken_languages.destroy_all
    new_spoken_language_codes.each do |new_lang_code|
      @model.spoken_languages.build(language_code: new_lang_code)
    end
  end
end
```

#### Primary Key

Resources are always represented using a key of `id`. The resource will interrogate the model to find the primary key.
If the underlying model does not use `id` as the primary key _and_ does not support the `primary_key` method you
must use the `primary_key` method to tell the resource which field on the model to use as the primary key. **Note:**
this _must_ be the actual primary key of the model.

By default only integer values are allowed for primary key. To change this behavior you can set the `resource_key_type`
configuration option:

```ruby
JSONAPI.configure do |config|
  # Allowed values are :integer(default), :uuid, :string, or a proc
  config.resource_key_type = :uuid
end
```

##### Override key type on a resource

You can override the default resource key type on a per-resource basis by calling `key_type` in the resource class,
with the same allowed values as the `resource_key_type` configuration option.

```ruby
class ContactResource < JSONAPI::Resource
  attribute :id
  attributes :name_first, :name_last, :email, :twitter
  key_type :uuid
end
```

##### Custom resource key validators

If you need more control over the key, you can override the #verify_key method on your resource, or set a lambda that
accepts key and context arguments in `config/initializers/jsonapi_resources.rb`:

```ruby
JSONAPI.configure do |config|
  config.resource_key_type = -> (key, context) { key && String(key) }
end
```

#### Model Name

The name of the underlying model is inferred from the Resource name. It can be overridden by use of the `model_name`
method. For example:

```ruby
class AuthorResource < JSONAPI::Resource
  attribute :name
  model_name 'Person'
  has_many :posts
end
```

#### Model Hints

Resource instances are created from model records. The determination of the correct resource type is performed using a
simple rule based on the model's name. The name is used to find a resource in the same module (as the originating
resource) that matches the name. This usually works quite well, however it can fail when model names do not match
resource names. It can also fail when using namespaced models. In this case a `model_hint` can be created to map model
names to resources. For example:

```ruby
class AuthorResource < JSONAPI::Resource
  attribute :name
  model_name 'Person'
  model_hint model: Commenter, resource: :special_person

  has_many :posts
  has_many :commenters
end
```

Note that when `model_name` is set a corresponding `model_hint` is also added. This can be skipped by using the
`add_model_hint` option set to false. For example:

```ruby
class AuthorResource < JSONAPI::Resource
  model_name 'Legacy::Person', add_model_hint: false
end
```

Model hints inherit from parent resources, but are not global in scope. The `model_hint` method accepts `model` and
`resource` named parameters. `model` takes an ActiveRecord class or class name (defaults to the model name), and
`resource` takes a resource type or a resource class (defaults to the current resource's type).

#### Relationships

Related resources need to be specified in the resource. These may be declared with the `relationship` or the `has_one`
and the `has_many` methods.

Here's a simple example using the `relationship` method where a post has a single author and an author can have many
posts:

```ruby
class PostResource < JSONAPI::Resource
  attributes :title, :body

  relationship :author, to: :one
end
```

And the corresponding author:

```ruby
class AuthorResource < JSONAPI::Resource
  attribute :name

  relationship :posts, to: :many
end
```

And here's the equivalent resources using the `has_one` and `has_many` methods:

```ruby
class PostResource < JSONAPI::Resource
  attributes :title, :body

  has_one :author
end
```

And the corresponding author:

```ruby
class AuthorResource < JSONAPI::Resource
  attribute :name

  has_many :posts
end
```

##### Options

The relationship methods (`relationship`, `has_one`, and `has_many`) support the following options:

 * `class_name` - a string specifying the underlying class for the related resource. Defaults to the `class_name` property on the underlying model.
 * `foreign_key` - the method on the resource used to fetch the related resource. Defaults to `<resource_name>_id` for has_one and `<resource_name>_ids` for has_many relationships.
 * `acts_as_set` - allows the entire set of related records to be replaced in one operation. Defaults to false if not set.
 * `polymorphic` - set to true to identify relationships that are polymorphic.
 * `relation_name` - the name of the relation to use on the model. A lambda may be provided which allows conditional selection of the relation based on the context.
 * `always_include_linkage_data` - if set to true, the relationship includes linkage data. Defaults to false if not set.

`to_one` relationships support the additional option:
 * `foreign_key_on` - defaults to `:self`. To indicate that the foreign key is on the related resource specify `:related`.

Examples:

```ruby
class CommentResource < JSONAPI::Resource
  attributes :body
  has_one :post
  has_one :author, class_name: 'Person'
  has_many :tags, acts_as_set: true
end

class ExpenseEntryResource < JSONAPI::Resource
  attributes :cost, :transaction_date

  has_one :currency, class_name: 'Currency', foreign_key: 'currency_code'
  has_one :employee
end

class TagResource < JSONAPI::Resource
  attributes :name
  has_one :taggable, polymorphic: true
end
```

```ruby
class BookResource < JSONAPI::Resource

  # Only book_admins may see unapproved comments for a book. Using
  # a lambda to select the correct relation on the model
  has_many :book_comments, relation_name: -> (options = {}) {
    context = options[:context]
    current_user = context ? context[:current_user] : nil

    unless current_user && current_user.book_admin
      :approved_book_comments
    else
      :book_comments
    end
  }
  ...
end
```

The polymorphic relationship will require the resource and controller to exist, although routing to them will cause an
error.

```ruby
class TaggableResource < JSONAPI::Resource; end
class TaggablesController < JSONAPI::ResourceController; end
```

#### Filters

Filters for locating objects of the resource type are specified in the resource definition. Single filters can be
declared using the `filter` method, and multiple filters can be declared with the `filters` method on the resource
class.

For example:

```ruby
class ContactResource < JSONAPI::Resource
  attributes :name_first, :name_last, :email, :twitter

  filter :id
  filters :name_first, :name_last
end
```

Then a request could pass in a filter for example `http://example.com/contacts?filter[name_last]=Smith` and the system
will find all people where the last name exactly matches Smith.

##### Default Filters

A default filter may be defined for a resource using the `default` option on the `filter` method. This default is used
unless the request overrides this value.

For example:

```ruby
 class CommentResource < JSONAPI::Resource
  attributes :body, :status
  has_one :post
  has_one :author

  filter :status, default: 'published,pending'
end
```

The default value is used as if it came from the request.

##### Applying Filters

You may customize how a filter behaves by supplying a callable to the `:apply` option. This callable will be used to
apply that filter. The callable is passed the `records`, which is an `ActiveRecord::Relation`, the `value`, and an
`_options` hash. It is expected to return an `ActiveRecord::Relation`.

This example shows how you can implement different approaches for different filters.

```ruby
filter :visibility, apply: ->(records, value, _options) {
  records.where('users.publicly_visible = ?', value == :public)
}
```

If you omit the `apply` callable the filter will be applied as `records.where(filter => value)`.

Note: It is also possible to override the `self.apply_filter` method, though this approach is now deprecated:

```ruby
def self.apply_filter(records, filter, value, options)
  case filter
    when :last_name, :first_name, :name
      if value.is_a?(Array)
        value.each do |val|
          records = records.where(_model_class.arel_table[filter].matches(val))
        end
        return records
      else
        records.where(_model_class.arel_table[filter].matches(value))
      end
    else
      return super(records, filter, value)
  end
end
```

##### Verifying Filters

Because filters typically come straight from the request, it's prudent to verify their values. To do so, provide a
callable to the `verify` option. This callable will be passed the `value` and the `context`. Verify should return the
verified value, which may be modified.

```ruby
  filter :ids,
         verify: ->(values, context) {
           verify_keys(values, context)
           return values
         },
         apply: -> (records, value, _options) {
           records.where('id IN (?)', value)
         }
```

##### Finders

Basic finding by filters is supported by resources. This is implemented in the `find` and `find_by_key` finder methods.
Currently this is implemented for `ActiveRecord` based resources. The finder methods rely on the `records` method to get
an `ActiveRecord::Relation` relation. It is therefore possible to override `records` to affect the three find related
methods.

###### Customizing base records for finder methods

If you need to change the base records on which `find` and `find_by_key` operate, you can override the `records` method
on the resource class.

For example to allow a user to only retrieve his own posts you can do the following:

```ruby
class PostResource < JSONAPI::Resource
  attributes :title, :body

  def self.records(options = {})
    context = options[:context]
    context[:current_user].posts
  end
end
```

When you create a relationship, a method is created to fetch record(s) for that relationship, using the relation name
for the relationship.

```ruby
class PostResource < JSONAPI::Resource
  has_one :author
  has_many :comments

  # def record_for_author
  #   relation_name = relationship.relation_name(context: @context)
  #   records_for(relation_name)
  # end

  # def records_for_comments
  #   relation_name = relationship.relation_name(context: @context)
  #   records_for(relation_name)
  # end
end

```

For example, you may want to raise an error if the user is not authorized to view the related records. See the next
section for additional details on raising errors.

```ruby
class BaseResource < JSONAPI::Resource
  def records_for(relation_name)
    context = options[:context]
    records = _model.public_send(relation_name)

    unless context[:current_user].can_view?(records)
      raise NotAuthorizedError
    end

    records
  end
end
```

###### Raising Errors

Inside the finder methods (like `records_for`) or inside of resource callbacks
(like `before_save`) you can `raise` an error to halt processing. JSONAPI::Resources
has some built in errors that will return appropriate error codes. By
default any other error that you raise will return a `500` status code
for a general internal server error.

To return useful error codes that represent application errors you
should set the `exception_class_whitelist` config variable, and then you
should use the Rails `rescue_from` macro to render a status code.

For example, this config setting allows the `NotAuthorizedError` to bubble up out of
JSONAPI::Resources and into your application.

```ruby
# config/initializer/jsonapi-resources.rb
JSONAPI.configure do |config|
  config.exception_class_whitelist = [NotAuthorizedError]
end
```

Handling the error and rendering the appropriate code is now the resonsiblity of the
application and could be handled like this:

```ruby
class ApiController < ApplicationController
  rescue_from NotAuthorizedError, with: :reject_forbidden_request
  def reject_forbidden_request
    render json: {error: 'Forbidden'}, :status => 403
  end
end
```


###### Applying Filters

The `apply_filter` method is called to apply each filter to the `Arel` relation. You may override this method to gain
control over how the filters are applied to the `Arel` relation.

This example shows how you can implement different approaches for different filters.

```ruby
def self.apply_filter(records, filter, value, options)
  case filter
    when :visibility
      records.where('users.publicly_visible = ?', value == :public)
    when :last_name, :first_name, :name
      if value.is_a?(Array)
        value.each do |val|
          records = records.where(_model_class.arel_table[filter].matches(val))
        end
        return records
      else
        records.where(_model_class.arel_table[filter].matches(value))
      end
    else
      return super(records, filter, value)
  end
end
```


###### Applying Sorting

You can override the `apply_sort` method to gain control over how the sorting is done. This may be useful in case you'd
like to base the sorting on variables in your context.

Example:

```ruby
def self.apply_sort(records, order_options, context = {})
  if order_options.has?(:trending)
    records = records.order_by_trending_scope
    order_options - [:trending]
  end

  super(records, order_options, context)
end
```


###### Override finder methods

Finally if you have more complex requirements for finding you can override the `find` and `find_by_key` methods on the
resource class.

Here's an example that defers the `find` operation to a `current_user` set on the `context` option:

```ruby
class AuthorResource < JSONAPI::Resource
  attribute :name
  model_name 'Person'
  has_many :posts

  filter :name

  def self.find(filters, options = {})
    context = options[:context]
    authors = context[:current_user].find_authors(filters)

    return authors.map do |author|
      self.new(author, context)
    end
  end
end
```

#### Pagination

Pagination is performed using a `paginator`, which is a class responsible for parsing the `page` request parameters and
applying the pagination logic to the results.

##### Paginators

`JSONAPI::Resource` supports several pagination methods by default, and allows you to implement a custom system if the
defaults do not meet your needs.

###### Paged Paginator

The `paged` `paginator` returns results based on pages of a fixed size. Valid `page` parameters are `number` and `size`.
If `number` is omitted the first page is returned. If `size` is omitted the `default_page_size` from the configuration
settings is used.

```
GET /articles?page%5Bnumber%5D=10&page%5Bsize%5D=10 HTTP/1.1
Accept: application/vnd.api+json
```

###### Offset Paginator

The `offset` `paginator` returns results based on an offset from the beginning of the resultset. Valid `page` parameters
are `offset` and `limit`. If `offset` is omitted a value of 0 will be used. If `limit` is omitted the `default_page_size`
from the configuration settings is used.

```
GET /articles?page%5Blimit%5D=10&page%5Boffset%5D=10 HTTP/1.1
Accept: application/vnd.api+json
```

###### Custom Paginators

Custom `paginators` can be used. These should derive from `Paginator`. The `apply` method takes a `relation` and
`order_options` and is expected to return a `relation`. The `initialize` method receives the parameters from the `page`
request parameters. It is up to the paginator author to parse and validate these parameters.

For example, here is a very simple single record at a time paginator:

```ruby
class SingleRecordPaginator < JSONAPI::Paginator
  def initialize(params)
    # param parsing and validation here
    @page = params.to_i
  end

  def apply(relation, order_options)
    relation.offset(@page).limit(1)
  end
end
```

##### Paginator Configuration

The default paginator, which will be used for all resources, is set using `JSONAPI.configure`. For example, in your
`config/initializers/jsonapi_resources.rb`:

```ruby
JSONAPI.configure do |config|
  # built in paginators are :none, :offset, :paged
  config.default_paginator = :offset

  config.default_page_size = 10
  config.maximum_page_size = 20
end
```

If no `default_paginator` is configured, pagination will be disabled by default.

Paginators can also be set at the resource-level, which will override the default setting. This is done using the
`paginator` method:

```ruby
class BookResource < JSONAPI::Resource
  attribute :title
  attribute :isbn

  paginator :offset
end
```

To disable pagination in a resource, specify `:none` for `paginator`.

#### Included relationships (side-loading resources)

JR supports [request include params](http://jsonapi.org/format/#fetching-includes) out of the box, for side loading related resources.

Here's an example from the spec:

```
GET /articles/1?include=comments HTTP/1.1
Accept: application/vnd.api+json
```

Will get you the following payload by default:

```
{
  "data": {
    "type": "articles",
    "id": "1",
    "attributes": {
      "title": "JSON API paints my bikeshed!"
    },
    "links": {
      "self": "http://example.com/articles/1"
    },
    "relationships": {
      "comments": {
        "links": {
          "self": "http://example.com/articles/1/relationships/comments",
          "related": "http://example.com/articles/1/comments"
        },
        "data": [
          { "type": "comments", "id": "5" },
          { "type": "comments", "id": "12" }
        ]
      }
    }
  },
  "included": [{
    "type": "comments",
    "id": "5",
    "attributes": {
      "body": "First!"
    },
    "links": {
      "self": "http://example.com/comments/5"
    }
  }, {
    "type": "comments",
    "id": "12",
    "attributes": {
      "body": "I like XML better"
    },
    "links": {
      "self": "http://example.com/comments/12"
    }
  }]
}
```

#### Resource Meta

Meta information can be included for each resource using the meta method in the resource declaration. For example:

```ruby
class BookResource < JSONAPI::Resource
  attribute :title
  attribute :isbn

  def meta(options)
    {
      copyright: 'API Copyright 2015 - XYZ Corp.',
      computed_copyright: options[:serialization_options][:copyright],
      last_updated_at: _model.updated_at
    }
   end
end

```

The `meta` method will be called for each resource instance. Override the `meta` method on a resource class to control
the meta information for the resource. If a non empty hash is returned from `meta` this will be serialized. The `meta`
method is called with an `options` hash. The `options` hash will contain the following:

 * `:serializer` -> the serializer instance
 * `:serialization_options` -> the contents of the `serialization_options` method on the controller.

#### Custom Links

Custom links can be included for each resource by overriding the `custom_links` method. If a non empty hash is returned from `custom_links`, it will be merged with the default links hash containing the resource's `self` link. The `custom_links` method is called with the same `options` hash used by for [resource meta information](#resource-meta). The `options` hash contains the following:

 * `:serializer` -> the serializer instance
 * `:serialization_options` -> the contents of the `serialization_options` method on the controller.

For example:

```ruby
class CityCouncilMeeting < JSONAPI::Resource
  attribute :title, :location, :approved

  def custom_links(options)
    { minutes: options[:serializer].link_builder.self_link(self) + "/minutes" }
  end
end
```

This will create a custom link with the key `minutes`, which will be merged with the default `self` link, like so:

```json
{
  "data": [
    {
      "id": "1",
      "type": "cityCouncilMeetings",
      "links": {
        "self": "http://city.gov/api/city-council-meetings/1",
        "minutes": "http://city.gov/api/city-council-meetings/1/minutes"
      },
      "attributes": {...}
    },
    //...
  ]
}
```

Of course, the `custom_links` method can include logic to include links only when relevant:

````ruby
class CityCouncilMeeting < JSONAPI::Resource
  attribute :title, :location, :approved

  delegate :approved?, to: :model

  def custom_links(options)
    extra_links = {}
    if approved?
      extra_links[:minutes] = options[:serializer].link_builder.self_link(self) + "/minutes"
    end
    extra_links
  end
end
```

It's also possibly to suppress the default `self` link by returning a hash with `{self: nil}`:

````ruby
class Selfless < JSONAPI::Resource
  def custom_links(options)
    {self: nil}
  end
end
```

#### Callbacks

`ActiveSupport::Callbacks` is used to provide callback functionality, so the behavior is very similar to what you may be
used to from `ActiveRecord`.

For example, you might use a callback to perform authorization on your resource before an action.

```ruby
class BaseResource < JSONAPI::Resource
  before_create :authorize_create

  def authorize_create
    # ...
  end
end
```

The types of supported callbacks are:
- `before`
- `after`
- `around`

##### `JSONAPI::Resource` Callbacks

Callbacks can be defined for the following `JSONAPI::Resource` events:

- `:create`
- `:update`
- `:remove`
- `:save`
- `:create_to_many_link`
- `:replace_to_many_links`
- `:create_to_one_link`
- `:replace_to_one_link`
- `:remove_to_many_link`
- `:remove_to_one_link`
- `:replace_fields`

##### `JSONAPI::Processor` Callbacks

Callbacks can also be defined for `JSONAPI::Processor` events:
- `:operation`: Any individual operation.
- `:find`: A `find` operation is being processed.
- `:show`: A `show` operation is being processed.
- `:show_relationship`: A `show_relationship` operation is being processed.
- `:show_related_resource`: A `show_related_resource` operation is being processed.
- `:show_related_resources`: A `show_related_resources` operation is being processed.
- `:create_resource`: A `create_resource` operation is being processed.
- `:remove_resource`: A `remove_resource` operation is being processed.
- `:replace_fields`: A `replace_fields` operation is being processed.
- `:replace_to_one_relationship`: A `replace_to_one_relationship` operation is being processed.
- `:create_to_many_relationship`: A `create_to_many_relationship` operation is being processed.
- `:replace_to_many_relationship`: A `replace_to_many_relationship` operation is being processed.
- `:remove_to_many_relationship`: A `remove_to_many_relationship` operation is being processed.
- `:remove_to_one_relationship`: A `remove_to_one_relationship` operation is being processed.

See [Operation Processors] (#operation-processors) for details on using OperationProcessors

##### `JSONAPI::OperationsProcessor` Callbacks (a removed feature)

Note: The `JSONAPI::OperationsProcessor` has been removed and replaced with the `JSONAPI::OperationDispatcher`
and `Processor` classes per resource. The callbacks have been renamed and moved to the
`Processor`s, with the exception of the `operations` callback which is now on the controller.

### Controllers

There are two ways to implement a controller for your resources. Either derive from `ResourceController` or import
the `ActsAsResourceController` module.

##### ResourceController

`JSONAPI::Resources` provides a class, `ResourceController`, that can be used as the base class for your controllers.
`ResourceController` supports `index`, `show`, `create`, `update`, and `destroy` methods. Just deriving your controller
from `ResourceController` will give you a fully functional controller.

For example:

```ruby
class PeopleController < JSONAPI::ResourceController

end
```

Of course you are free to extend this as needed and override action handlers or other methods.

A jsonapi-controller generator is avaliable

```
rails generate jsonapi:controller contact
```

###### ResourceControllerMetal

`JSONAPI::Resources` also provides an alternative class to `ResourceController` called `ResourceControllerMetal`.
In order to provide a lighter weight controller option this strips the controller down to just the classes needed
to work with `JSONAPI::Resources`.

For example:

```ruby
class PeopleController < JSONAPI::ResourceControllerMetal

end
```

Note: This may not provide all of the expected controller capabilities if you are using additional gems such as DoorKeeper.

###### Serialization Options

Additional options can be passed to the serializer using the `serialization_options` method.

For example:

```ruby
class ApplicationController < JSONAPI::ResourceController
  def serialization_options
    {copyright: 'Copyright 2015'}
  end
end
```

These `serialization_options` are passed to the `meta` method used to generate resource `meta` values.

##### ActsAsResourceController

`JSONAPI::Resources` also provides a module, `JSONAPI::ActsAsResourceController`. You can include this module to
mix in all the features of `ResourceController` into your existing controller class.

For example:

```ruby
class PostsController < ActionController::Base
  include JSONAPI::ActsAsResourceController
end
```

#### Namespaces

JSONAPI::Resources supports namespacing of controllers and resources. With namespacing you can version your API.

If you namespace your controller it will require a namespaced resource.

In the following example we have a `resource` that isn't namespaced, and one the has now been namespaced. There are
slight differences between the two resources, as might be seen in a new version of an API:

```ruby
class PostResource < JSONAPI::Resource
  attribute :title
  attribute :body
  attribute :subject

  has_one :author, class_name: 'Person'
  has_one :section
  has_many :tags, acts_as_set: true
  has_many :comments, acts_as_set: false
  def subject
    @model.title
  end

  filters :title, :author, :tags, :comments
  filter :id
end

...

module Api
  module V1
    class PostResource < JSONAPI::Resource
      # V1 replaces the non-namespaced resource
      # V1 no longer supports tags and now calls author 'writer'
      attribute :title
      attribute :body
      attribute :subject

      has_one :writer, foreign_key: 'author_id'
      has_one :section
      has_many :comments, acts_as_set: false

      def subject
        @model.title
      end

      filters :writer
    end

    class WriterResource < JSONAPI::Resource
      attributes :name, :email
      model_name 'Person'
      has_many :posts

      filter :name
    end
  end
end
```

The following controllers are used:

```ruby
class PostsController < JSONAPI::ResourceController
end

module Api
  module V1
    class PostsController < JSONAPI::ResourceController
    end
  end
end
```

You will also need to namespace your routes:

```ruby
Rails.application.routes.draw do

  jsonapi_resources :posts

  namespace :api do
    namespace :v1 do
      jsonapi_resources :posts
    end
  end
end
```

When a namespaced `resource` is used, any related `resources` must also be in the same namespace.

#### Error codes

Error codes are provided for each error object returned, based on the error. These errors are:

```ruby
module JSONAPI
  VALIDATION_ERROR = '100'
  INVALID_RESOURCE = '101'
  FILTER_NOT_ALLOWED = '102'
  INVALID_FIELD_VALUE = '103'
  INVALID_FIELD = '104'
  PARAM_NOT_ALLOWED = '105'
  PARAM_MISSING = '106'
  INVALID_FILTER_VALUE = '107'
  COUNT_MISMATCH = '108'
  KEY_ORDER_MISMATCH = '109'
  KEY_NOT_INCLUDED_IN_URL = '110'
  INVALID_INCLUDE = '112'
  RELATION_EXISTS = '113'
  INVALID_SORT_CRITERIA = '114'
  INVALID_LINKS_OBJECT = '115'
  TYPE_MISMATCH = '116'
  INVALID_PAGE_OBJECT = '117'
  INVALID_PAGE_VALUE = '118'
  INVALID_FIELD_FORMAT = '119'
  INVALID_FILTERS_SYNTAX = '120'
  SAVE_FAILED = '121'
  FORBIDDEN = '403'
  RECORD_NOT_FOUND = '404'
  NOT_ACCEPTABLE = '406'
  UNSUPPORTED_MEDIA_TYPE = '415'
  LOCKED = '423'
end
```

These codes can be customized in your app by creating an initializer to override any or all of the codes.

In addition textual error codes can be returned by setting the configuration option `use_text_errors = true`. For
example:

```ruby
JSONAPI.configure do |config|
  config.use_text_errors = true
end
```


#### Handling Exceptions

By default, all exceptions raised downstream from a resource controller will be caught, logged, and a ```500 Internal Server Error``` will be rendered. Exceptions can be whitelisted in the config to pass through the handler and be caught manually, or you can pass a callback from a resource controller to insert logic into the rescue block without interrupting the control flow. This can be particularly useful for additional logging or monitoring without the added work of rendering responses.

Pass a block, refer to controller class methods, or both. Note that methods must be defined as class methods on a controller and accept one parameter, which is passed the exception object that was rescued.

```ruby
  class ApplicationController < JSONAPI::ResourceController

    on_server_error :first_callback

    #or

    # on_server_error do |error|
      #do things
    #end

    def self.first_callback(error)
      #env["airbrake.error_id"] = notify_airbrake(error)
    end
  end

```

#### Action Callbacks

##### ensure_correct_media_type

By default, when controllers extend functionalities from `jsonapi-resources`, the `ActsAsResourceController#ensure_correct_media_type`
method will be triggered before `create`, `update`, `create_relationship` and `update_relationship` actions. This method is reponsible
for checking if client's request corresponds to the correct media type required by [JSON API](http://jsonapi.org/format/#content-negotiation-clients): `application/vnd.api+json`.

In case you need to check the media type for custom actions, just make sure to call the method in your controller's `before_action`:

```ruby
class UsersController < JSONAPI::ResourceController
  before_action :ensure_correct_media_type, only: [:auth]

  def auth
    # some crazy auth code goes here
  end
end
```

### Operation Processors

Operation Processors are called to perform the operation(s) that make up a request. The controller (through the `OperationDispatcher`), creates an `OperatorProcessor` to handle each operation. The processor is created based on the resource name, including the namespace. If a processor does not exist for a resource (namespace matters) the default operation processor is used instead. The default processor can be changed by a configuration setting.

Defining a custom `Processor` allows for custom callback handling of each operation type for each resource type. For example:

```ruby
class Api::V4::BookProcessor < JSONAPI::Processor
  after_find do
    unless @result.is_a?(JSONAPI::ErrorsOperationResult)
      @result.meta[:total_records_found] = @result.record_count
    end
  end
end
```

This simple example uses a callback to update the result's meta property with the total count of records (a redundant
feature only for example purposes), if there wasn't an error in the operation.  It is also possible to override the
`find` method as well if a different behavior is needed, for example:

```ruby
class Api::V4::BookProcessor < JSONAPI::Processor
  def find
    filters = params[:filters]
    include_directives = params[:include_directives]
    sort_criteria = params.fetch(:sort_criteria, [])
    paginator = params[:paginator]

    verified_filters = resource_klass.verify_filters(filters, context)
    resource_records = resource_klass.find(verified_filters,
                                           context: context,
                                           include_directives: include_directives,
                                           sort_criteria: sort_criteria,
                                           paginator: paginator)

    page_options = {}
    # Overriding the default record count logic to always include it in the meta
    #if (JSONAPI.configuration.top_level_meta_include_record_count ||
    #  (paginator && paginator.class.requires_record_count))
      page_options[:record_count] = resource_klass.find_count(verified_filters,
                                                              context: context,
                                                              include_directives: include_directives)
    #end
end
```

Note: The authors of this gem expect the most common uses cases to be handled using the callbacks. It is likely that the
internal functionality of the operation processing methods will change, at least for several revisions. Effort will be
made to call this out in release notes. You have been warned.

### Serializer

The `ResourceSerializer` can be used to serialize a resource into JSON API compliant JSON. `ResourceSerializer` must be
 initialized with the primary resource type it will be serializing. `ResourceSerializer` has a `serialize_to_hash`
 method that takes a resource instance or array of resource instances to serialize. For example:

```ruby
post = Post.find(1)
JSONAPI::ResourceSerializer.new(PostResource).serialize_to_hash(PostResource.new(post, nil))
```

This returns results like this:

```json
{
  "data": {
    "type": "posts",
    "id": "1",
    "links": {
      "self": "http://example.com/posts/1"
    },
    "attributes": {
      "title": "New post",
      "body": "A body!!!",
      "subject": "New post"
    },
    "relationships": {
      "section": {
        "links": {
          "self": "http://example.com/posts/1/relationships/section",
          "related": "http://example.com/posts/1/section"
        },
        "data": null
      },
      "author": {
        "links": {
          "self": "http://example.com/posts/1/relationships/author",
          "related": "http://example.com/posts/1/author"
        },
        "data": {
          "type": "people",
          "id": "1"
        }
      },
      "tags": {
        "links": {
          "self": "http://example.com/posts/1/relationships/tags",
          "related": "http://example.com/posts/1/tags"
        }
      },
      "comments": {
        "links": {
          "self": "http://example.com/posts/1/relationships/comments",
          "related": "http://example.com/posts/1/comments"
        }
      }
    }
  }
}
```

#### Serializer options

The `ResourceSerializer` can be initialized with some optional parameters:

##### `include`

An array of resources. Nested resources can be specified with dot notation.

  *Purpose*: determines which objects will be side loaded with the source objects in an `included` section

  *Example*: ```include: ['comments','author','comments.tags','author.posts']```

##### `fields`

A hash of resource types and arrays of fields for each resource type.

  *Purpose*: determines which fields are serialized for a resource type. This encompasses both attributes and
  relationship ids in the links section for a resource. Fields are global for a resource type.

  *Example*: ```fields: { people: [:email, :comments], posts: [:title, :author], comments: [:body, :post]}```

```ruby
post = Post.find(1)
include_resources = ['comments','author','comments.tags','author.posts']

JSONAPI::ResourceSerializer.new(PostResource, include: include_resources,
  fields: {
    people: [:email, :comments],
    posts: [:title, :author],
    tags: [:name],
    comments: [:body, :post]
  }
).serialize_to_hash(PostResource.new(post, nil))
```

#### Formatting

JR by default uses some simple rules to format (and unformat) an attribute for (de-)serialization. Strings and Integers are output to JSON
as is, and all other values have `.to_s` applied to them. This outputs something in all cases, but it is certainly not
correct for every situation.

If you want to change the way an attribute is (de-)serialized you have a couple of ways. The simplest method is to create a
getter (and setter) method on the resource which overrides the attribute and apply the (un-)formatting there. For example:

```ruby
class PersonResource < JSONAPI::Resource
  attributes :name, :email, :last_login_time

  # Setter example
  def email=(new_email)
    @model.email = new_email.downcase
  end

  # Getter example
  def last_login_time
    @model.last_login_time.in_time_zone(@context[:current_user].time_zone).to_s
  end
end
```

This is simple to implement for a one off situation, but not for example if you want to apply the same formatting rules
to all DateTime fields in your system. Another issue is the attribute on the resource will always return a formatted
response, whether you want it or not.

##### Value Formatters

To overcome the above limitations JR uses Value Formatters. Value Formatters allow you to control the way values are
handled for an attribute. The `format` can be set per attribute as it is declared in the resource. For example:

```ruby
class PersonResource < JSONAPI::Resource
  attributes :name, :email, :spoken_languages
  attribute :last_login_time, format: :date_with_utc_timezone

  # Getter/Setter for spoken_languages ...
end
```

A Value formatter has a `format` and an `unformat` method. Here's the base ValueFormatter and DefaultValueFormatter for
reference:

```ruby
module JSONAPI
  class ValueFormatter < Formatter
    class << self
      def format(raw_value)
        super(raw_value)
      end

      def unformat(value)
        super(value)
      end
      ...
    end
  end
end

class DefaultValueFormatter < JSONAPI::ValueFormatter
  class << self
    def format(raw_value)
      case raw_value
        when Date, Time, DateTime, ActiveSupport::TimeWithZone, BigDecimal
          # Use the as_json methods added to various base classes by ActiveSupport
          return raw_value.as_json
        else
          return raw_value
      end
    end
  end
end
```

You can also create your own Value Formatter. Value Formatters must be named with the `format` name followed by
`ValueFormatter`, i.e. `DateWithUTCTimezoneValueFormatter` and derive from `JSONAPI::ValueFormatter`. It is
recommended that you create a directory for your formatters, called `formatters`.

The `format` method is called by the `ResourceSerializer` as is serializing a resource. The format method takes the
`raw_value` parameter. `raw_value` is the value as read from the model.

The `unformat` method is called when processing the request. Each incoming attribute (except `links`) are run through
the `unformat` method. The `unformat` method takes a `value`, which is the value as it comes in on the
request. This allows you process the incoming value to alter its state before it is stored in the model.

###### Use a Different Default Value Formatter

Another way to handle formatting is to set a different default value formatter. This will affect all attributes that do
not have a `format` set. You can do this by overriding the `default_attribute_options` method for a resource (or a base
resource for a system wide change).

```ruby
  def default_attribute_options
    {format: :my_default}
  end
```

and

```ruby
class MyDefaultValueFormatter < DefaultValueFormatter
  class << self
    def format(raw_value)
      case raw_value
        when DateTime
          return super(raw_value.in_time_zone('UTC'))
        else
          return super
      end
    end
  end
end
```

This way all DateTime values will be formatted to display in the UTC timezone.

#### Key Format

By default JR uses dasherized keys as per the
[JSON API naming recommendations](http://jsonapi.org/recommendations/#naming).  This can be changed by specifying a
different key formatter.

For example, to use camel cased keys with an initial lowercase character (JSON's default) create an initializer and add
the following:

```ruby
JSONAPI.configure do |config|
  # built in key format options are :underscored_key, :camelized_key and :dasherized_key
  config.json_key_format = :camelized_key
end
```

This will cause the serializer to use the `CamelizedKeyFormatter`. You can also create your own `KeyFormatter`, for
example:

```ruby
class UpperCamelizedKeyFormatter < JSONAPI::KeyFormatter
  class << self
    def format(key)
      super.camelize(:upper)
    end
  end
end
```

You would specify this in `JSONAPI.configure` as `:upper_camelized`.

### Routing

JR has a couple of helper methods available to assist you with setting up routes.

##### `jsonapi_resources`

Like `resources` in `ActionDispatch`, `jsonapi_resources` provides resourceful routes mapping between HTTP verbs and URLs
and controller actions. This will also setup mappings for relationship URLs for a resource's relationships. For example:

```ruby
Rails.application.routes.draw do
  jsonapi_resources :contacts
  jsonapi_resources :phone_numbers
end
```

gives the following routes

```
                     Prefix Verb      URI Pattern                                               Controller#Action
contact_relationships_phone_numbers GET       /contacts/:contact_id/relationships/phone-numbers(.:format)       contacts#show_relationship {:relationship=>"phone_numbers"}
                            POST      /contacts/:contact_id/relationships/phone-numbers(.:format)       contacts#create_relationship {:relationship=>"phone_numbers"}
                            DELETE    /contacts/:contact_id/relationships/phone-numbers/:keys(.:format) contacts#destroy_relationship {:relationship=>"phone_numbers"}
      contact_phone_numbers GET       /contacts/:contact_id/phone-numbers(.:format)             phone_numbers#get_related_resources {:relationship=>"phone_numbers", :source=>"contacts"}
                   contacts GET       /contacts(.:format)                                       contacts#index
                            POST      /contacts(.:format)                                       contacts#create
                    contact GET       /contacts/:id(.:format)                                   contacts#show
                            PATCH     /contacts/:id(.:format)                                   contacts#update
                            PUT       /contacts/:id(.:format)                                   contacts#update
                            DELETE    /contacts/:id(.:format)                                   contacts#destroy
 phone_number_relationships_contact GET       /phone-numbers/:phone_number_id/relationships/contact(.:format)   phone_numbers#show_relationship {:relationship=>"contact"}
                            PUT|PATCH /phone-numbers/:phone_number_id/relationships/contact(.:format)   phone_numbers#update_relationship {:relationship=>"contact"}
                            DELETE    /phone-numbers/:phone_number_id/relationships/contact(.:format)   phone_numbers#destroy_relationship {:relationship=>"contact"}
       phone_number_contact GET       /phone-numbers/:phone_number_id/contact(.:format)         contacts#get_related_resource {:relationship=>"contact", :source=>"phone_numbers"}
              phone_numbers GET       /phone-numbers(.:format)                                  phone_numbers#index
                            POST      /phone-numbers(.:format)                                  phone_numbers#create
               phone_number GET       /phone-numbers/:id(.:format)                              phone_numbers#show
                            PATCH     /phone-numbers/:id(.:format)                              phone_numbers#update
                            PUT       /phone-numbers/:id(.:format)                              phone_numbers#update
                            DELETE    /phone-numbers/:id(.:format)                              phone_numbers#destroy
```

##### `jsonapi_resource`

Like `jsonapi_resources`, but for resources you lookup without an id.

#### Nested Routes

By default nested routes are created for getting related resources and manipulating relationships. You can control the
nested routes by passing a block into `jsonapi_resources` or `jsonapi_resource`. An empty block will not create
any nested routes. For example:

```ruby
Rails.application.routes.draw do
  jsonapi_resources :contacts do
  end
end
```

gives routes that are only related to the primary resource, and none for its relationships:

```
      Prefix Verb   URI Pattern                  Controller#Action
    contacts GET    /contacts(.:format)          contacts#index
             POST   /contacts(.:format)          contacts#create
     contact GET    /contacts/:id(.:format)      contacts#show
             PATCH  /contacts/:id(.:format)      contacts#update
             PUT    /contacts/:id(.:format)      contacts#update
             DELETE /contacts/:id(.:format)      contacts#destroy
```

To manually add in the nested routes you can use the `jsonapi_links`, `jsonapi_related_resources` and
`jsonapi_related_resource` inside the block. Or, you can add the default set of nested routes using the
`jsonapi_relationships` method. For example:

```ruby
Rails.application.routes.draw do
  jsonapi_resources :contacts do
    jsonapi_relationships
  end
end
```

###### `jsonapi_links`

You can add relationship routes in with `jsonapi_links`, for example:

```ruby
Rails.application.routes.draw do
  jsonapi_resources :contacts do
    jsonapi_links :phone_numbers
  end
end
```

Gives the following routes:

```
contact_relationships_phone_numbers GET    /contacts/:contact_id/relationships/phone-numbers(.:format)       contacts#show_relationship {:relationship=>"phone_numbers"}
                            POST   /contacts/:contact_id/relationships/phone-numbers(.:format)       contacts#create_relationship {:relationship=>"phone_numbers"}
                            DELETE /contacts/:contact_id/relationships/phone-numbers/:keys(.:format) contacts#destroy_relationship {:relationship=>"phone_numbers"}
                   contacts GET    /contacts(.:format)                                       contacts#index
                            POST   /contacts(.:format)                                       contacts#create
                    contact GET    /contacts/:id(.:format)                                   contacts#show
                            PATCH  /contacts/:id(.:format)                                   contacts#update
                            PUT    /contacts/:id(.:format)                                   contacts#update
                            DELETE /contacts/:id(.:format)                                   contacts#destroy

```

The new routes allow you to show, create and destroy the relationships between resources.

###### `jsonapi_related_resources`

Creates a nested route to GET the related has_many resources. For example:

```ruby
Rails.application.routes.draw do
  jsonapi_resources :contacts do
    jsonapi_related_resources :phone_numbers
  end
end

```

gives the following routes:

```
               Prefix Verb   URI Pattern                                   Controller#Action
contact_phone_numbers GET    /contacts/:contact_id/phone-numbers(.:format) phone_numbers#get_related_resources {:relationship=>"phone_numbers", :source=>"contacts"}
             contacts GET    /contacts(.:format)                           contacts#index
                      POST   /contacts(.:format)                           contacts#create
              contact GET    /contacts/:id(.:format)                       contacts#show
                      PATCH  /contacts/:id(.:format)                       contacts#update
                      PUT    /contacts/:id(.:format)                       contacts#update
                      DELETE /contacts/:id(.:format)                       contacts#destroy

```

A single additional route was created to allow you GET the phone numbers through the contact.

###### `jsonapi_related_resource`

Like `jsonapi_related_resources`, but for has_one related resources.

```ruby
Rails.application.routes.draw do
  jsonapi_resources :phone_numbers do
    jsonapi_related_resource :contact
  end
end
```

gives the following routes:

```
              Prefix Verb   URI Pattern                                       Controller#Action
phone_number_contact GET    /phone-numbers/:phone_number_id/contact(.:format) contacts#get_related_resource {:relationship=>"contact", :source=>"phone_numbers"}
       phone_numbers GET    /phone-numbers(.:format)                          phone_numbers#index
                     POST   /phone-numbers(.:format)                          phone_numbers#create
        phone_number GET    /phone-numbers/:id(.:format)                      phone_numbers#show
                     PATCH  /phone-numbers/:id(.:format)                      phone_numbers#update
                     PUT    /phone-numbers/:id(.:format)                      phone_numbers#update
                     DELETE /phone-numbers/:id(.:format)                      phone_numbers#destroy

```

### Resource Caching

To improve the response time of GET requests, JR can cache the generated JSON fragments for
Resources which are suitable. First, set `config.resource_cache` to an ActiveSupport cache store:

```ruby
JSONAPI.configure do |config|
  config.resource_cache = Rails.cache
end
```

Then, on each Resource you want to cache, call the `caching` method:

```ruby
class PostResource << JSONAPI::Resource
  caching
end
```

See the caveats section below for situations where you might not want to enable caching on particular
Resources.

The Resource model must also have a field that is updated whenever any of the model's data changes.
The default Rails timestamps handle this pretty well, and the default cache key field is `updated_at` for this reason.
You can use an alternate field (which you are then responsible for updating) by calling the `cache_field` method:

```ruby
class PostResource << JSONAPI::Resource
  cache_field :change_counter

  before_save do
    if self.change_counter.nil?
      self.change_counter = 1
    elsif self.changed?
      self.change_counter += 1
    end
  end

  after_touch do
    update_attribute(:change_counter, self.change_counter + 1)
  end
end
```

If context affects the content of the serialized result, you must define a class method `attribute_caching_context` on that Resource, which should return a different value for contexts that produce different results. In particular, if the `meta` or `fetchable_fields` methods, or any method providing the actual content of an attribute, changes depending on context, then you must provide `attribute_caching_context`. The actual value it
returns isn't important, except that the value must be different if any relevant aspect of the context is different.

```ruby
class PostResource << JSONAPI::Resource
  attributes :title, :body, :secret_field

  def fetchable_fields
    return super if context.user.superuser?
    return super - [:secret_field]
  end

  def meta
    if context.user.can_see_creation_dates?
      return { created: _model.created_at }
    else
      return {}
    end
  end

  def self.attribute_caching_context(context)
    return {
      admin: context.user.superuser?,
      creation_date_viewer: context.user.can_see_creation_dates?
    }
  end
end
```

#### Caching Caveats

* Models for cached Resources must update a cache key field whenever their data changes. However, if you bypass Rails and e.g. alter the database row directly without changing the `updated_at` field, the cached entry for that resource will be inaccurate. Also, `updated_at` provides a narrow race condition window; if a resource is updated twice in the same second, it's possible that only the first update will be cached. If you're concerned about this, you will need to find a way to make sure your models' cache fields change on every update, e.g. by using a unique random value or a monotonic clock.
* If an attribute's value is affected by related resources, e.g. the `spoken_languages` example above, then changes to the related resource must also touch the cache field on the resource that uses it. The `belongs_to` relation in ActiveRecord provides a `:touch` option for this purpose.
* JR does not actively clean the cache, so you must use an ActiveSupport cache that automatically expires old entries, or you will leak resources. The MemoryCache built in to Rails does this by default, but other caches will have to be configured with an `:expires_in` option and/or a cache-specific clearing mechanism.
* Similarly, if you make a substantial code change that affects a lot of serialized representations (i.e. changing the way an attribute is shown), you'll have to clear out all relevant cache entries yourself. You do not have to do this after merely adding or removing attributes; only changes that affect the actual content of attributes require manual cache clearing. The simplest way to do this is to run `JSONAPI.configuration.resource_cache.clear` from the console.
* If resource caching is enabled at all, then custom relationship methods on any resource might not always be used, even resources that are not cached. For example, if you manually define a `comments` method or `records_for_comments` method on a Resource that `has_many :comments`, you cannot expect it to be used when caching is enabled, even if you never call `caching` on that particular Resource. Instead, you should use relationship name lambdas.
* The above also applies to custom `find` or `find_by_key` methods. Instead, if you are using resource caching anywhere in your app, try overriding the `find_records` method to return an appropriate `ActiveRecord::Relation`.
* Caching relies on ActiveRecord features; you cannot enable caching on resources based on non-AR models, e.g. PORO objects or singleton resources.
* If you write a custom `ResourceSerializer` which takes new options, then you must define `config_description` to include those options if they might impact the serialized value:

```ruby
class MySerializer << JSONAPI::ResourceSerializer
  def initialize(primary_resource_klass, options = {})
    @my_special_option = options.delete(:my_special_option)
    super
  end

  def config_description(resource_klass)
    super.merge({my_special_option: @my_special_option})
  end
end
```

## Configuration

JR has a few configuration options. Some have already been mentioned above. To set configuration options create an
initializer and add the options you wish to set. All options have defaults, so you only need to set the options that
are different. The default options are shown below.

If using custom classes (such as a CustomPaginator), be sure to require them at the top of the initializer before usage.

```ruby
JSONAPI.configure do |config|
  #:underscored_key, :camelized_key, :dasherized_key, or custom
  config.json_key_format = :dasherized_key

  #:underscored_route, :camelized_route, :dasherized_route, or custom
  config.route_format = :dasherized_route

  # Default Processor, used if a resource specific one is not defined.
  # Must be a class
  config.default_processor_klass = JSONAPI::Processor

  #:integer, :uuid, :string, or custom (provide a proc)
  config.resource_key_type = :integer

  # optional request features
  config.allow_include = true
  config.allow_sort = true
  config.allow_filter = true

  # How to handle unsupported attributes and relationships which are provided in the request
  # true => raises an error
  # false => allows the request to continue. A warning is included in the response meta data indicating
  # the fields which were ignored. This is useful for client libraries which send extra parameters.
  config.raise_if_parameters_not_allowed = true

  # :none, :offset, :paged, or a custom paginator name
  config.default_paginator = :none

  # Output pagination links at top level
  config.top_level_links_include_pagination = true

  config.default_page_size = 10
  config.maximum_page_size = 20

  # Output the record count in top level meta data for find operations
  config.top_level_meta_include_record_count = false
  config.top_level_meta_record_count_key = :record_count

  # For :paged paginators, the following are also available
  config.top_level_meta_include_page_count = false
  config.top_level_meta_page_count_key = :page_count

  config.use_text_errors = false

  # List of classes that should not be rescued by the operations processor.
  # For example, if you use Pundit for authorization, you might
  # raise a Pundit::NotAuthorizedError at some point during operations
  # processing. If you want to use Rails' `rescue_from` macro to
  # catch this error and render a 403 status code, you should add
  # the `Pundit::NotAuthorizedError` to the `exception_class_whitelist`.
  # Subclasses of the whitelisted classes will also be whitelisted.
  config.exception_class_whitelist = []

  # Resource Linkage
  # Controls the serialization of resource linkage for non compound documents
  # NOTE: always_include_to_many_linkage_data is not currently implemented
  config.always_include_to_one_linkage_data = false

  # Formatter Caching
  # Set to false to disable caching of string operations on keys and links.
  # Note that unlike the resource cache, formatter caching is always done
  # internally in-memory and per-thread; no ActiveSupport::Cache is used.
  config.cache_formatters = true

  # Resource cache
  # An ActiveSupport::Cache::Store or similar, used by Resources with caching enabled.
  # Set to `nil` (the default) to disable caching, or to `Rails.cache` to use the
  # Rails cache store.
  config.resource_cache = nil

  # Default resource cache field
  # On Resources with caching enabled, this field will be used to check for out-of-date
  # cache entries, unless overridden on a specific Resource. Defaults to "updated_at".
  config.default_resource_cache_field = :updated_at

  # Resource cache digest function
  # Provide a callable that returns a unique value for string inputs with
  # low chance of collision. The default is SHA256 base64.
  config.resource_cache_digest_function = Digest::SHA2.new.method(:base64digest)

  # Resource cache usage reporting
  # Optionally provide a callable which JSONAPI will call with information about cache
  # performance. Should accept three arguments: resource name, hits count, misses count.
  config.resource_cache_usage_report_function = nil
end
```

## Contributing

1. Fork it ( http://github.com/cerebris/jsonapi-resources/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## License

Copyright 2014-2016 Cerebris Corporation. MIT License (see LICENSE for details).
