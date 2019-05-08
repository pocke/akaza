class Array
  def first
    self[0]
  end

  def empty?
    size == 0
  end
end

class Integer
  def <(right)
    (self <=> right) == -1
  end

  def >(right)
    (self <=> right) == 1
  end

  def <=(right)
    (self <=> right) < 1
  end

  def >=(right)
    (self <=> right) > -1
  end
end

def p(obj)
  if obj.is_a?(Integer)
    put_as_number obj
  elsif obj.is_a?(Array)
    size = obj.size
    idx = 0
    put_as_char '['
    while idx < size
      p obj[idx]
      idx = idx + 1
      if idx != size
        put_as_char ','
        put_as_char ' '
      end
    end
    put_as_char ']'
  elsif obj.is_a?(Hash)
    raise "p(Hash) does not supported yet."
  elsif obj == nil
    put_as_char 'n'
    put_as_char 'i'
    put_as_char 'l'
  elsif obj == true
    put_as_char 't'
    put_as_char 'r'
    put_as_char 'u'
    put_as_char 'e'
  elsif obj == false
    put_as_char 'f'
    put_as_char 'a'
    put_as_char 'l'
    put_as_char 's'
    put_as_char 'e'
  else
    raise "Unknown"
  end
end
