namespace :pii_tokenizer do
  desc 'Backfill token columns for models with tokenized fields'
  task :backfill, %i[model_name batch_size] => :environment do |_t, args|
    model_name = args[:model_name]
    batch_size = (args[:batch_size] || 1000).to_i

    unless model_name
      puts 'Usage: rake pii_tokenizer:backfill[ModelName,batch_size]'
      puts 'Example: rake pii_tokenizer:backfill[User,1000]'
      exit(1)
    end

    begin
      model_class = model_name.constantize
    rescue NameError
      puts "Error: Model '#{model_name}' not found"
      exit(1)
    end

    unless model_class.include?(PiiTokenizer::Tokenizable)
      puts "Error: Model '#{model_name}' does not include PiiTokenizer::Tokenizable"
      exit(1)
    end

    puts "Starting backfill for #{model_name}"
    puts "Tokenized fields: #{model_class.tokenized_fields.inspect}"

    # Check if token columns exist
    token_columns = model_class.tokenized_fields.map { |field| "#{field}_token" }
    missing_columns = token_columns.reject { |col| model_class.column_names.include?(col) }

    if missing_columns.any?
      puts "Error: Missing token columns: #{missing_columns.join(', ')}"
      puts 'Please run migrations to add these columns before backfilling'
      exit(1)
    end

    # Configure for backfilling
    original_dual_write = model_class.dual_write_enabled
    original_read_from_token = model_class.read_from_token_column

    # For backfilling, we want dual-write but don't need to read from token
    model_class.dual_write_enabled = true
    model_class.read_from_token_column = false

    total_count = model_class.count
    processed_count = 0
    updated_count = 0
    batch_number = 0

    begin
      puts "Processing #{total_count} records in batches of #{batch_size}"

      model_class.find_in_batches(batch_size: batch_size) do |batch|
        batch_number += 1
        current_range = "#{processed_count + 1} - #{[processed_count + batch_size, total_count].min}"
        puts "Processing batch #{batch_number} (#{current_range} of #{total_count})"

        records_to_save = []

        batch.each do |record|
          # Check if any token column is empty
          needs_update = false

          model_class.tokenized_fields.each do |field|
            token_column = "#{field}_token"
            field_value = record.read_attribute(field)
            token_value = record.read_attribute(token_column)

            # Only tokenize if original field has value and token is missing
            if field_value.present? && token_value.blank?
              needs_update = true
              break
            end
          end

          records_to_save << record if needs_update
        end

        if records_to_save.any?
          ActiveRecord::Base.transaction do
            records_to_save.each do |record|
              # Force re-encryption by marking fields as changed
              model_class.tokenized_fields.each do |field|
                value = record.read_attribute(field)
                if value.present?
                  record.instance_variable_set("@original_#{field}", value)
                end
              end

              record.save!
              updated_count += 1
            end
          end

          puts "  Updated #{records_to_save.size} records in this batch"
        else
          puts '  No records needed updating in this batch'
        end

        processed_count += batch.size
        puts "Progress: #{processed_count}/#{total_count} (#{(processed_count.to_f / total_count * 100).round(2)}%)"
      end

      puts "\nBackfill completed:"
      puts "  Total records processed: #{processed_count}"
      puts "  Records updated: #{updated_count}"
    ensure
      # Restore original settings
      model_class.dual_write_enabled = original_dual_write
      model_class.read_from_token_column = original_read_from_token
    end
  end
end
