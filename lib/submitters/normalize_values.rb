# frozen_string_literal: true

module Submitters
  module NormalizeValues
    CHECKSUM_CACHE_STORE = ActiveSupport::Cache::MemoryStore.new

    UnknownFieldName = Class.new(StandardError)
    UnknownSubmitterName = Class.new(StandardError)

    module_function

    def call(template, values, submitter_name: nil, for_submitter: nil, throw_errors: false)
      fields = fetch_fields(template, submitter_name:, for_submitter:)

      fields_uuid_index = fields.index_by { |e| e['uuid'] }
      fields_name_index = build_fields_index(fields)

      attachments = []

      normalized_values = values.to_h.filter_map do |key, value|
        if fields_uuid_index[key].blank?
          key = fields_name_index[key]&.dig('uuid')

          raise(UnknownFieldName, "Unknown field: #{key}") if key.blank? && throw_errors
        end

        next if key.blank?

        if fields_uuid_index[key]['type'].in?(%w[initials signature image file])
          new_value, new_attachments = normalize_attachment_value(value, template.account, for_submitter)

          attachments.push(*new_attachments)

          value = new_value
        end

        [key, value]
      end.to_h

      [normalized_values, attachments]
    end

    def fetch_fields(template, submitter_name: nil, for_submitter: nil)
      if submitter_name
        submitter =
          template.submitters.find { |e| e['name'] == submitter_name } ||
          raise(UnknownSubmitterName, "Unknown submitter: #{submitter_name}")
      end

      fields = for_submitter&.submission&.template_fields || template.fields

      fields.select { |e| e['submitter_uuid'] == (for_submitter&.uuid || submitter['uuid']) }
    end

    def build_fields_index(fields)
      fields.index_by { |e| e['name'] }.merge(fields.index_by { |e| e['name'].to_s.parameterize.underscore })
    end

    def normalize_attachment_value(value, account, for_submitter = nil)
      if value.is_a?(Array)
        new_attachments = value.map { |v| find_or_build_attachment(v, account, for_submitter) }

        [new_attachments.map(&:uuid), new_attachments]
      else
        new_attachment = find_or_build_attachment(value, account, for_submitter)

        [new_attachment.uuid, new_attachment]
      end
    end

    def find_or_build_attachment(value, account, for_submitter = nil)
      blob = find_or_create_blobs(account, value)

      attachment = for_submitter.attachments.find_by(blob_id: blob.id) if for_submitter

      attachment ||= ActiveStorage::Attachment.new(
        blob:,
        name: 'attachments'
      )

      attachment
    end

    def find_or_create_blobs(account, url)
      cache_key = [account.id, url].join(':')
      checksum = CHECKSUM_CACHE_STORE.fetch(cache_key)

      blob = find_blob_by_checksum(checksum, account) if checksum

      return blob if blob

      data = conn.get(Addressable::URI.parse(url).display_uri.to_s).body

      checksum = Digest::MD5.base64digest(data)

      CHECKSUM_CACHE_STORE.write(cache_key, checksum)

      blob = find_blob_by_checksum(checksum, account)

      blob || ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(data),
        filename: Addressable::URI.parse(url).path.split('/').last
      )
    end

    def find_blob_by_checksum(checksum, account)
      ActiveStorage::Blob
        .joins('JOIN active_storage_attachments ON active_storage_attachments.blob_id = active_storage_blobs.id')
        .where(active_storage_attachments: { record_id: account.submitters.select(:id),
                                             record_type: 'Submitter' })
        .find_by(checksum:)
    end

    def conn
      Faraday.new do |faraday|
        faraday.response :follow_redirects
      end
    end
  end
end
