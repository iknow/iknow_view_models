# frozen_string_literal: true

require 'json'
require 'json_schema'

class ViewModel::Schemas
  JsonSchema.configure do |c|
    uuid_format = /\A[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\Z/
    c.register_format('uuid', ->(value) { uuid_format.match(value) })
  end

  ID_SCHEMA =
    { 'oneOf' => [{ 'type' => 'integer' },
                  { 'type' => 'string', 'format' => 'uuid' },] }.freeze

  ID = JsonSchema.parse!(ID_SCHEMA)

  VIEWMODEL_UPDATE_SCHEMA =
    {
      'type'        => 'object',
      'description' => 'viewmodel update',
      'properties'  => { ViewModel::TYPE_ATTRIBUTE    => { 'type' => 'string' },
                         ViewModel::ID_ATTRIBUTE      => ID_SCHEMA,
                         ViewModel::NEW_ATTRIBUTE     => { 'type' => 'boolean' },
                         ViewModel::VERSION_ATTRIBUTE => { 'type' => 'integer' } },
      'required'    => [ViewModel::TYPE_ATTRIBUTE],
    }.freeze

  VIEWMODEL_UPDATE = JsonSchema.parse!(VIEWMODEL_UPDATE_SCHEMA)

  VIEWMODEL_REFERENCE_SCHEMA =
    {
      'type'                 => 'object',
      'description'          => 'viewmodel shared reference',
      'properties'           => { ViewModel::REFERENCE_ATTRIBUTE => { 'type' => 'string' } },
      'additionalProperties' => false,
      'required'             => [ViewModel::REFERENCE_ATTRIBUTE],
    }.freeze

  VIEWMODEL_REFERENCE = JsonSchema.parse!(VIEWMODEL_REFERENCE_SCHEMA)

  BULK_UPDATE_SCHEMA =
    {
      'type'                 => 'object',
      'description'          => 'bulk update collection',
      'properties'           => {
        ViewModel::TYPE_ATTRIBUTE => {
          'type' => 'string',
          'enum' => [ViewModel::BULK_UPDATE_TYPE],
        },

        ViewModel::BULK_UPDATES_ATTRIBUTE => {
          'type'  => 'array',
          'items' => {
            'type'                 => 'object',
            'properties'           => {
              ViewModel::ID_ATTRIBUTE => ID_SCHEMA,

              # These will be checked by the main deserialize operation. Any operations on the data
              # before the main serialization must do its own checking of the presented update data.

              ViewModel::BULK_UPDATE_ATTRIBUTE => {
                'oneOf' => [
                  { 'type' => 'array' },
                  { 'type' => 'object' },
                ]
              },
            },
            'additionalProperties' => false,
            'required'             => [
              ViewModel::ID_ATTRIBUTE,
              ViewModel::BULK_UPDATE_ATTRIBUTE,
            ],
          },
        }
      },
      'additionalProperties' => false,
      'required'             => [
        ViewModel::TYPE_ATTRIBUTE,
        ViewModel::BULK_UPDATES_ATTRIBUTE,
      ],
    }.freeze

  BULK_UPDATE = JsonSchema.parse!(BULK_UPDATE_SCHEMA)

  def self.verify_schema!(schema, value)
    valid, errors = schema.validate(value)
    unless valid
      error_list = errors.map { |e| "#{e.pointer}: #{e.message}" }.join("\n")
      errors     = 'Error'.pluralize(errors.length)
      raise ViewModel::DeserializationError::InvalidSyntax.new("#{errors} parsing #{schema.description}:\n#{error_list}")
    end
  end
end
