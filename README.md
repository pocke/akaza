# Akaza

A cool Whitespace language implementation in Ruby.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'akaza'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install akaza


## Requirements

* `RUBY_VERSION > '2.6'`
  * It needs pattern match feature.

## Basic Usage

```ruby
require 'akaza'

# It use $stdin and $stdout
Akaza.eval(whitespace_code)

# Use other IO
input = StringIO.new(something)
output = StringIO.new
Akaza.eval(whitespace_code, input: input, output: output)
```

You can find example Whitespace programs from test/fixtures/ directory.

## Cool Usage

The basic usage is good, but it is not fun.
Akaza provides really "cool" interface to define a method with Whitespace.
You can write Whitespace in Ruby program directly!

For example:

```ruby
require 'akaza'

class A
  extend Akaza::Annotation

  whitespace def sum(a, b)
 	  

 	  input=StringIO.new("#{a}\n#{b}\n")
	  output=StringIO.new 	
 	



    Akaza::Body
    
	
	
    
		output.string.to_i	
	
end
end

a = A.new
p a.sum(20, 22) # => 42
```

Cool! You no longer need to write Whitespace as a string literal. You can write Whitespace in Ruby seamlessly. It is elegant!


### Requirements of cool style

* Space, tab and newline in method body are evaluated as Whitespace program.
  * Other characters are ignored for Whitespace, but they are evaluated as Ruby program.
* `Akaza::Body` is replaced with Whitespace code.
* `input` and `output` variables are necessary. They are IO.



Akaza provides a shorthand.
If `Akaza::Body` is omitted, the method only evaluates Whitespace program. The method receives `input` and `output`.

For example:

```
require 'akaza'

class A
  extend Akaza::Annotation

  whitespace def sum(input, output)
 	  

 	  
This	code is never evaluated.	
 	



So you can write any
sentences as comments!  
	
	
    
			
	
end
end

a = A.new
input = StringIO.new("20\n22\n")
output = StringIO.new
a.sum(input, output)
p output.string
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/pocke/akaza.
