# frozen_string_literal: true

if defined?(Rails::Railtie)
  module QualityGate
    # Integrates Quality Gate's generator and task files with Rails applications.
    class Railtie < Rails::Railtie
      generators do
        require_relative "../generators/quality_gate/install/install_generator"
      end

      rake_tasks do
        Dir[File.expand_path("../tasks/**/*.rake", __dir__)].sort.each { load _1 }
      end
    end
  end
end
