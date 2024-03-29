{application, mqtt_broker, 
  [{description, "An MQTT broker in erlang"}, 
  {vsn, "0.2.0"}, 
  {modules, [id,
    mqtt_store,
    mqtt_core,
    mqtt_client,
    mqtt_broker,
    mqtt_registry]}, 
  {registered,[]}, 
  {applications, [kernel,stdlib]}, 
  {env,[]},
  {mod, {mqtt_broker_app,[]}}, 
  {start_phases, []} 
]}.
