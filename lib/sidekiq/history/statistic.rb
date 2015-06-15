module Sidekiq
  module History
    class Statistic
      JOB_STATES = [:passed, :failed]

      def self.pubsub
        begin
          Sidekiq.redis do |conn|
            conn.subscribe(:'sidekiq:history-live') do |on|
              on.subscribe do |channel, subscriptions|
                puts "Subscribed to ##{channel} (#{subscriptions} subscriptions)"
              end

              on.message do |channel, message|
                puts "#{channel}: #{message}"
                redis.unsubscribe if message == "exit"
              end

              on.unsubscribe do |channel, subscriptions|
                puts "Unsubscribed from #{channel} (#{subscriptions} subscriptions)"
              end
            end
          end
        rescue Redis::BaseConnectionError => error
          puts "#{error}, retrying in 1s"
          sleep 1
          retry
        end
      end

      def initialize(days_previous, start_date = nil)
        @start_date = start_date || Time.now.utc.to_date
        @end_date = @start_date - days_previous
      end

      def display
        redis_statistic.worker_names.map do |worker|
          {
            name: worker,
            last_job_status: last_job_status_for(worker),
            number_of_calls: number_of_calls(worker),
            runtime: runtime_statistic(worker).values_hash
          }
        end
      end

      def display_pre_day(worker_name)
        redis_statistic.hash.flat_map do |day|
          day.reject{ |_, workers| workers.empty? }.map do |date, workers|
            worker_data = workers[worker_name]
            next unless worker_data

            {
              date: date,
              failure: worker_data[:failed],
              success: worker_data[:passed],
              total: worker_data[:failed] + worker_data[:passed],
              last_job_status: worker_data[:last_job_status],
              runtime: runtime_for_day(worker_name, worker_data)
            }
          end
        end.compact.reverse
      end

      def runtime_for_day(worker_name, worker_data)
        runtime_statistic(worker_name, worker_data[:runtime])
          .values_hash
          .merge!(last: worker_data[:last_runtime])
      end

      def number_of_calls(worker)
        number_of_calls = JOB_STATES.map{ |state| number_of_calls_for state, worker }

        {
          success: number_of_calls.first,
          failure: number_of_calls.last,
          total: number_of_calls.inject(:+)
        }
      end

      def number_of_calls_for(state, worker)
        redis_statistic.for_worker(worker)
          .select(&:any?)
          .map{ |hash| hash[state] }.inject(:+) || 0
      end

      def last_job_status_for(worker)
        redis_statistic
          .for_worker(worker)
          .select(&:any?)
          .last[:last_job_status]
      end

      def runtime_statistic(worker, values = nil)
        RuntimeStatistic.new(redis_statistic, worker, values)
      end

      def redis_statistic
        RedisStatistic.new(@start_date, @end_date)
      end
    end
  end
end
