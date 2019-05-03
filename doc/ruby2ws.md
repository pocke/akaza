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

```ruby
x = [1, 2, 3]
put_as_number x[0]
```

It support only a few methods.

* `shift`
* `unshift`
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

It only allows `something == 0` or `something < 0` as condition.


### while

You can use `while`.

```ruby
x = -10
while x < 0
  put_as_number x
  x = x + 1
end
```

It only allows `something == 0` or `something < 0` as condition.

### add, sub, multi, div, mod

You can use operators, that are `+`, `-`, `*`, `/` and `%`.

```ruby
put_as_number 1 + 2
put_as_number 1 - 2
put_as_number 1 * 2
put_as_number 4 / 2
put_as_number 10 % 3
```