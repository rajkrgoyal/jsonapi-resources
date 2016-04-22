require File.expand_path('../../test_helper', __FILE__)

class RequestBenchmark < IntegrationBenchmark
  def setup
    $test_user = Person.find(1)
  end

  def bench_large_index_request
    10.times do
      get '/api/v2/books?include=bookComments,bookComments.author'
      assert_jsonapi_response 200
    end
  end
end
