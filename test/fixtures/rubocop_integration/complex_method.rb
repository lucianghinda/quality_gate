def complex_example(value, items)
  total = 0
  status = if value > 10
    :large
  elsif value > 5
    :medium
  else
    :small
  end

  items.each do |item|
    total += item
    total += 1 if item.odd?
  end

  case status
  when :large
    total += 3
  when :medium
    total += 2
  else
    total += 1
  end

  if total > 20
    total -= 5
  else
    total += 5
  end

  total
end
