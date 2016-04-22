require File.expand_path('../../../test_helper', __FILE__)

class DasherizedKeyFormatterTest < ActiveSupport::TestCase
  def test_dasherize_camelize
    formatted = DasherizedKeyFormatter.new.format("CarWash")
    assert_equal formatted, "car-wash"
  end
end
