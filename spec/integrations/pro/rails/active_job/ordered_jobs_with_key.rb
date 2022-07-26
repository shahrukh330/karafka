# frozen_string_literal: true

# When using the pro adapter, we should be able to use partitioner that will allow us to process
# ActiveJob jobs in their scheduled order using multiple partitions. We should be able to get
# proper results when using `:key`.

setup_karafka do |config|
  config.license.token = pro_license_token
  config.initial_offset = 'latest'
end

setup_active_job

# This is a special topic with 3 partitions
TOPIC = 'integrations_02_03'

draw_routes do
  consumer_group DataCollector.consumer_group do
    active_job_topic TOPIC
  end
end

class Job < ActiveJob::Base
  queue_as TOPIC

  karafka_options(
    dispatch_method: :produce_sync,
    partitioner: ->(job) { job.arguments.first[0] },
    partition_key_type: :key
  )

  def perform(value1)
    DataCollector[0] << value1
  end
end

counts = 0

# First loop kicks in before initialization of the connection and we want to publish after, that
# is why we don't run it on the first run
Karafka::App.monitor.subscribe('connection.listener.fetch_loop') do
  counts += 1

  if counts == 5
    # We dispatch in order per partition, in case it all would go to one without partitioner or
    # in case it would fail, the order will break
    2.downto(0) do |partition|
      3.times do |iteration|
        Job.perform_later("#{partition}#{iteration}")
      end
    end
  end
end

start_karafka_and_wait_until do
  DataCollector[0].size >= 9
end

groups = DataCollector[0].group_by { |element| element[0] }
groups.transform_values! { |group| group.map(&:to_i) }

groups.each do |_, values|
  assert_equal values.sort, values
end