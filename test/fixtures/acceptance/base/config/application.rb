# frozen_string_literal: true

require_relative 'boot'
require 'rails'
require 'rails/test_unit/railtie'

Bundler.require(*Rails.groups)

module AcceptanceHost
  class Application < Rails::Application
    config.load_defaults 8.0
    config.eager_load = false
  end
end
