Wsrb
===

Wsrb is a language to write whitespace easily.
It is a subset of Ruby syntactically. It is almost a subset of Ruby semantically.

Usage
---

```ruby
# test.ws.rb
def calc(x, y)
  x + y
end

put_as_number(calc(1, 2))
```

```bash
$ akaza wsrb test.ws.rb > test.ws
$ akaza exec test.ws # => 3
```


Supported feature
---



### Differences from Ruby


#### built-in functions

Wsrb has methods that are not included in Ruby.

* `get_as_char`
* `get_as_number`
* `put_as_char`
* `put_as_number`


#### Character equals Integer

Wsrb does not distinguish between character and integer, like C language.



### Method definition and call

You can define method at the top level.

```ruby
def put_3_times(ch)
  put_as_char ch
  put_as_char ch
  put_as_char ch
end

put_3_times('a') # => aaa
```

It only allows argument without default value. It also does not allow keyword argument, rest argument, and so on.

Arguments number is not checked.


### Extend existing classes

You can define instance methods for existing classes, that are `Array`, `Hash` and `Integer`.

```ruby
class Hash
  def fetch(key)
    self[key]
  end
end
```

### Literals

You can use Integer and Character literal.
Character literal is a String literal, but it has only one character.
And character will be converted to Integer that is based on code point implicitly.

```ruby
put_as_char 'A'   # => A
put_as_number 'A' # => 65
put_as_number 42  # => 42
```

### Array

You can use Array. It is implemented as a linked list.

Must not access to out of range of array.

```ruby
x = [1, 2, 3]
put_as_number x[0]
```

It support only a few methods.

* `shift`
* `unshift`
* `[]`
* `[]=`
* `first`

### Hash

You can use Hash.

```ruby
x = {
  1 => 2,
  3 => 4,
}

x[5] = 6
put_as_number x[1] # => 2
x[100] # => nil
```

It supports only a few methods.

* `[]`
* `[]=`

### Local variables

You can use local variables.

```
x = 1

def foo
  x = 2
  put_as_number x
end

foo # => 2
put_as_number x # => 1
```


### if / unless

You can use `if` and `unless`.

```ruby
x = 0
if x == 0
  put_as_number x
else
  put_as_number 2
end

put_as_number 3 unless x < 0
```


### while

You can use `while`.

```ruby
x = -10
while x < 0
  put_as_number x
  x = x + 1
end
```

### add, sub, multi, div, mod

You can use operators, that are `+`, `-`, `*`, `/` and `%`.

```ruby
put_as_number 1 + 2
put_as_number 1 - 2
put_as_number 1 * 2
put_as_number 4 / 2
put_as_number 10 % 3
```

### exception

You can use `raise` method to raise an exception.

```ruby
raise "This is error message"
```

Program will exit by `raise` method with error message.
But the exit status is `0`.


Implementation
---

### Array

A linked list.

An Array object uses one heap.

* address to the first item

An item uses two heaps.

* value
* address to the next item

Address to the next item will be `NONE_ADDR` if the item is the last.


### Hash

It is implemented with Hash table and use chaining to resolve collision.


A Hash object uses one heap.

* address to the first item

An item uses three heaps.

* key
* value
* address to the next chain

On initialize, it reserve `HASH_SIZE * 3` heaps. And it sets `NONE` to all keys.
Value and address is not initialized. Do not access these heaps before initializing.
