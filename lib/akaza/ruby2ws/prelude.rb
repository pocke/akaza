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
