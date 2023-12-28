# frozen_string_literal: true

module Submissions
  module NormalizeParamUtils
    module_function

    def normalize_submissions_params!(submissions_params, template)
      attachments = []

      Array.wrap(submissions_params).each do |submission|
        submission[:submitters].each_with_index do |submitter, index|
          _, new_attachments = normalize_submitter_params!(submitter, template, index)

          attachments.push(*new_attachments)
        end
      end

      [submissions_params, attachments]
    end

    def normalize_submitter_params!(submitter_params, template, index = nil, for_submitter: nil)
      default_values = submitter_params[:values] || {}

      submitter_params[:fields]&.each do |f|
        default_values[f[:name]] = f[:default_value] if f[:default_value].present?
      end

      return submitter_params if default_values.blank?

      values, new_attachments =
        Submitters::NormalizeValues.call(template,
                                         default_values,
                                         submitter_name: submitter_params[:role] ||
                                                         template.submitters.dig(index, 'name'),
                                         for_submitter:,
                                         throw_errors: true)

      submitter_params[:values] = values

      [submitter_params, new_attachments]
    end

    def save_default_value_attachments!(attachments, submitters)
      return if attachments.blank?

      attachments_index = attachments.index_by(&:uuid)

      submitters.each do |submitter|
        submitter.values.to_a.each do |_, value|
          attachment = attachments_index[value]

          next unless attachment

          attachment.record = submitter

          attachment.save!
        end
      end
    end
  end
end
