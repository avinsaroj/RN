# frozen_string_literal: true

module Submitters
  module SubmitValues
    ValidationError = Class.new(StandardError)

    VARIABLE_REGEXP = /\{\{?(\w+)\}\}?/

    module_function

    def call(submitter, params, request)
      Submissions.update_template_fields!(submitter.submission) if submitter.submission.template_fields.blank?

      unless submitter.submission_events.exists?(event_type: 'start_form')
        SubmissionEvents.create_with_tracking_data(submitter, 'start_form', request)

        SendFormStartedWebhookRequestJob.perform_later(submitter)
      end

      update_submitter!(submitter, params, request)

      submitter.submission.save!

      ProcessSubmitterCompletionJob.perform_later(submitter) if submitter.completed_at?

      submitter
    end

    def update_submitter!(submitter, params, request)
      values = normalized_values(params)

      submitter.values.merge!(values)
      submitter.opened_at ||= Time.current

      if params[:completed] == 'true'
        submitter.completed_at = Time.current
        submitter.ip = request.remote_ip
        submitter.ua = request.user_agent
        submitter.values = merge_default_values(submitter)
      end

      ApplicationRecord.transaction do
        validate_values!(values, submitter, params, request)

        SubmissionEvents.create_with_tracking_data(submitter, 'complete_form', request) if params[:completed] == 'true'

        submitter.save!
      end

      submitter
    end

    def normalized_values(params)
      params.fetch(:values, {}).to_unsafe_h.transform_values do |v|
        if params[:cast_boolean] == 'true'
          v == 'true'
        elsif params[:normalize_phone] == 'true'
          v.to_s.gsub(/[^0-9+]/, '')
        else
          v.is_a?(Array) ? v.compact_blank : v
        end
      end
    end

    def validate_values!(values, submitter, params, request)
      values.each do |key, value|
        field = submitter.submission.template_fields.find { |e| e['uuid'] == key }

        validate_value!(value, field, params, submitter, request)
      end
    end

    def merge_default_values(submitter)
      default_values = submitter.submission.template_fields.each_with_object({}) do |field, acc|
        next if field['submitter_uuid'] != submitter.uuid

        value = field['default_value']

        next if value.blank?

        acc[field['uuid']] = template_default_value_for_submitter(value, submitter, with_time: true)
      end

      default_values.compact_blank.merge(submitter.values)
    end

    def template_default_value_for_submitter(value, submitter, with_time: false)
      return if value.blank?
      return if submitter.blank?

      role = submitter.submission.template_submitters.find { |e| e['uuid'] == submitter.uuid }['name']

      replace_default_variables(value,
                                submitter.attributes.merge('role' => role),
                                submitter.submission.template,
                                with_time:)
    end

    def replace_default_variables(value, attrs, template, with_time: false)
      return if value.blank?

      value.to_s.gsub(VARIABLE_REGEXP) do |e|
        case key = ::Regexp.last_match(1)
        when 'time'
          if with_time
            I18n.l(Time.current.in_time_zone(template.account.timezone), format: :long, locale: template.account.locale)
          else
            e
          end
        when 'date'
          if with_time
            I18n.l(Time.current.in_time_zone(template.account.timezone).to_date)
          else
            e
          end
        when 'role', 'email', 'phone', 'name'
          attrs[key] || e
        else
          e
        end
      end
    end

    def validate_value!(_value, _field, _params, _submitter, _request)
      true
    end
  end
end
