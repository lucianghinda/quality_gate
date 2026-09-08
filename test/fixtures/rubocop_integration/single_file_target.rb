# frozen_string_literal: true

class SingleFileTarget
  def call(value)
    value.to_s.upcase
  end
end
