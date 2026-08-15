# frozen_string_literal: true

module OpenAI
  module Auth
    # Coordinates cached workload identity credentials across threads.
    #
    # @api private
    class WorkloadIdentityAuth
      SUBJECT_TOKEN_TYPES = TokenExchange::SUBJECT_TOKEN_TYPES
      TOKEN_EXCHANGE_GRANT_TYPE = TokenExchange::GRANT_TYPE
      DEFAULT_TOKEN_EXCHANGE_URL = TokenExchange::DEFAULT_URL
      DEFAULT_REFRESH_BUFFER_SECONDS = 1200

      def initialize(
        config,
        _organization_id,
        token_exchange_url: DEFAULT_TOKEN_EXCHANGE_URL,
        http_client: nil,
        sleeper: ->(delay) { sleep(delay) },
        monotonic_clock: -> { OpenAI::Internal::Util.monotonic_secs }
      )
        @refresh_buffer_seconds = config.refresh_buffer_seconds
        @token_exchange = TokenExchange.build(
          config,
          token_exchange_url: token_exchange_url,
          http_client: http_client,
          sleeper: sleeper
        )
        @monotonic_clock = monotonic_clock

        @cached_token = nil
        @cached_token_expires_at_monotonic = nil
        @cached_token_refresh_at_monotonic = nil
        @refreshing = false
        @mutex = Mutex.new
        @cond_var = ConditionVariable.new
      end

      # @api private
      def get_token
        @mutex.synchronize do
          if @refreshing
            return @cached_token unless token_unusable?

            @cond_var.wait(@mutex) while @refreshing
            raise token_refresh_error if token_unusable?

            return @cached_token
          end

          return @cached_token unless token_unusable? || needs_refresh?

          @refreshing = true
        end

        perform_refresh
        @mutex.synchronize do
          raise token_refresh_error if token_unusable?

          @cached_token
        end
      end

      # Invalidate only the credential that was rejected when it is supplied.
      # This prevents a late 401 from discarding a token refreshed by another
      # request.
      #
      # @api private
      def invalidate_token(rejected_token = nil)
        @mutex.synchronize do
          return nil unless rejected_token.nil? || rejected_token == @cached_token

          @cached_token = nil
          @cached_token_expires_at_monotonic = nil
          @cached_token_refresh_at_monotonic = nil
        end
        nil
      end

      # @api private
      def inspect
        state = @mutex.synchronize { [!@cached_token.nil?, @refreshing] }
        "#<#{self.class.name}:0x#{object_id.to_s(16)} cached=#{state.fetch(0)} " \
          "refreshing=#{state.fetch(1)}>"
      end

      private

      def perform_refresh
        token_data = @token_exchange.fetch
        now = @monotonic_clock.call
        expires_in = token_data.fetch(:expires_in)

        @mutex.synchronize do
          @cached_token = token_data.fetch(:id)
          @cached_token_expires_at_monotonic = now + expires_in
          @cached_token_refresh_at_monotonic = now + refresh_delay_seconds(expires_in)
        end
      ensure
        @mutex.synchronize do
          @refreshing = false
          @cond_var.broadcast
        end
      end

      def token_unusable?
        @cached_token.nil? || token_expired?
      end

      def token_expired?
        return true if @cached_token_expires_at_monotonic.nil?

        @monotonic_clock.call >= @cached_token_expires_at_monotonic
      end

      def needs_refresh?
        return false if @cached_token_refresh_at_monotonic.nil?

        @monotonic_clock.call >= @cached_token_refresh_at_monotonic
      end

      def refresh_delay_seconds(expires_in)
        configured_buffer = @refresh_buffer_seconds || DEFAULT_REFRESH_BUFFER_SECONDS
        effective_buffer = [configured_buffer, expires_in / 2.0].min

        [expires_in - effective_buffer, 0].max
      end

      def token_refresh_error
        OpenAI::Errors::AuthenticationError.new(
          url: @token_exchange.url,
          status: 401,
          headers: nil,
          body: nil,
          request: nil,
          response: nil,
          message: "Token refresh failed"
        )
      end
    end
  end
end
