# frozen_string_literal: true

abort 'Rails was loaded by the Ruby profile' if defined?(Rails)

require 'minitest/autorun'
