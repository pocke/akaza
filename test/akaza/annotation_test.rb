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

  def test_whitespace_with_placeholder
    klass = Class.new do
      extend Akaza::Annotation
      whitespace def sum(a, b)#call
 	  
#call
 	  
#add	   writenum	
 	#exit
input=StringIO.new("#{a}\n#{b}\n");
output=StringIO.new;
#label
    Akaza::Body;
#push0    
#readnum	
		#push0    
#readheap			end
	output.string.to_i
end
    end

    i = klass.new
    assert_equal 15, i.sum(10, 5)
  end
end
