# frozen_string_literal: true

require_relative "test_helper"

AcceptanceDatabaseConfig = Data.define(:name)
AcceptanceConnectionPool = Data.define(:db_config)

class AcceptanceConnection
  def adapter_name = "Acceptance"

  def pool
    @pool ||= AcceptanceConnectionPool.new(AcceptanceDatabaseConfig.new("primary"))
  end
end

class AcceptanceMigration
  include StrongMigrations::Migration

  def version = 20_260_102_000_000

  def connection
    @connection ||= AcceptanceConnection.new
  end

  def reverting? = false
end

class UnsafeMigrationTest < Minitest::Test
  def test_strong_migrations_rejects_an_unsafe_column_type_change
    assert_equal StrongMigrations::Migration, AcceptanceMigration.instance_method(:stop!).owner

    ddl_executed = false
    checker = StrongMigrations::Checker.new(AcceptanceMigration.new)
    checker.direction = :up

    error = assert_raises(StrongMigrations::UnsafeMigration) do
      checker.perform(:change_column, :users, :name, :text) { ddl_executed = true }
    end

    refute ddl_executed, "Strong Migrations must reject change_column before executing DDL"
    assert_includes error.message, "Dangerous operation detected #strong_migrations"
    flunk error.message
  end
end
