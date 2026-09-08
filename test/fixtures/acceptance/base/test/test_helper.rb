# frozen_string_literal: true

ENV['RAILS_ENV'] ||= 'test'
# Bullet selects its Active Record integration when the generated initializer requires it.
require 'active_record'
require_relative '../config/environment'
require 'rails/test_help'
