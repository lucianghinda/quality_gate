# frozen_string_literal: true

require_relative "test_helper"

class AcceptanceRecord
  attr_reader :id

  def self.primary_key = :id

  def initialize(id) = @id = id

  def read_attribute(name) = public_send(name)
end

class NPlusOneTest < Minitest::Test
  def test_bullet_reports_the_unpreloaded_comments_association
    error = trigger_bullet_notification

    assert_includes error.message, "USE eager loading"
    assert_includes error.message, "AcceptanceRecord => [:comments]"
    flunk error.message
  end

  private

  def trigger_bullet_notification
    Bullet.start_request
    record = AcceptanceRecord.new(1)
    detector = Bullet::Detector::NPlusOneQuery
    detector.add_possible_objects(record)
    detector.call_association(record, :comments, caller_locations(0, 1))

    assert_raises(Bullet::Notification::UnoptimizedQueryError) do
      Bullet.perform_out_of_channel_notifications
    end
  ensure
    Bullet.end_request
  end
end
