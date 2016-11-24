require 'view_model'
require 'json'
require 'json_schema'

class ViewModel::Schemas
  JsonSchema.configure do |c|
    uuid_format = /\A[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\Z/
    c.register_format('uuid', ->(value) { uuid_format.match(value) })
  end

  ID_SCHEMA =
    { 'oneOf' => [{ 'type' => 'integer' },
                  { 'type' => 'string', 'format' => 'uuid' }] }
  ID = JsonSchema.parse!(ID_SCHEMA)

  VIEWMODEL_UPDATE_SCHEMA =
    {
      'type'        => 'object',
      'description' => 'viewmodel update',
      'properties'  => { ViewModel::TYPE_ATTRIBUTE    => { 'type' => 'string' },
                         ViewModel::ID_ATTRIBUTE      => ID_SCHEMA,
                         ViewModel::NEW_ATTRIBUTE     => { 'type' => 'boolean' },
                         ViewModel::VERSION_ATTRIBUTE => { 'type' => 'integer' } },
      'required'    => [ViewModel::TYPE_ATTRIBUTE]
    }
  VIEWMODEL_UPDATE = JsonSchema.parse!(VIEWMODEL_UPDATE_SCHEMA)

  VIEWMODEL_REFERENCE_SCHEMA =
    {
      'type'                 => 'object',
      'description'          => 'viewmodel shared reference',
      'properties'           => { ViewModel::REFERENCE_ATTRIBUTE => { 'type' => 'string' } },
      'additionalProperties' => false,
      'required'             => [ViewModel::REFERENCE_ATTRIBUTE],
    }
  VIEWMODEL_REFERENCE = JsonSchema.parse!(VIEWMODEL_REFERENCE_SCHEMA)

  def self.verify_schema!(schema, value)
    valid, errors = schema.validate(value)
    unless valid
      error_list = errors.map { |e| "#{e.pointer}: #{e.message}" }.join("\n")
      errors     = 'Error'.pluralize(errors.length)
      raise ViewModel::DeserializationError.new("#{errors} parsing #{schema.description}:\n#{error_list}")
    end
  end
end
