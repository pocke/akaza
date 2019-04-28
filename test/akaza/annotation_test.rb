require 'test_helper'

class AnnotationTest < Minitest::Test
  def test_whitespace
    klass = Class.new do
      extend Akaza::Annotation
      whitespace def sum(input, output)#call
 	  
#call
 	  
#add	   writenum	
 	#exit


#label
    
#push0    
#readnum	
	
#push0    
#readheap			end
	
end
    end

    i = klass.new
    input = StringIO.new("10\n32")
    output = StringIO.new
    i.sum(input, output)
    assert_equal "42", output.string
  end
end
