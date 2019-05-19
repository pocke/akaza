require 'test_helper'

class PreludeTest < Minitest::Test
  def test_array_last
    assert_eval "42", <<~RUBY
      put_as_number [1, 2, 42].last
    RUBY
  end

  def test_array_zip
    skip
    assert_eval "[[1, 5], [2, 6]]", <<~RUBY
      a = [1, 2]
      b = [5, 6]

      p a.zip(b)
    RUBY
  end
end
