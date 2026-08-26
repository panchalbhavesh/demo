-- Sample data for the demo. Assumes the 3-node cluster is up and no auth is
-- enabled yet (AllowAllAuthenticator, current state of this project). If
-- PasswordAuthenticator/CassandraAuthorizer get turned on later, add
-- `-u <user> -p <password>` to the cqlsh invocation used to run this file.

-- SimpleStrategy, not NetworkTopologyStrategy: our StatefulSet doesn't set
-- --endpoint-snitch, so ScyllaDB defaults to SimpleSnitch, which reports
-- every node as datacenter "datacenter1" regardless of AZ. NetworkTopology
-- would need the real DC name (confirm with `nodetool status`). SimpleStrategy
-- sidesteps that and just replicates across the ring, which is fine for a
-- single-DC demo like this one.
CREATE KEYSPACE IF NOT EXISTS demo
  WITH replication = {
    'class': 'SimpleStrategy',
    'replication_factor': 3
  };

USE demo;

CREATE TABLE IF NOT EXISTS users (
  user_id   uuid PRIMARY KEY,
  name      text,
  email     text,
  created_at timestamp
);

INSERT INTO users (user_id, name, email, created_at)
  VALUES (uuid(), 'Alice Johnson', 'alice@example.com', toTimestamp(now()));
INSERT INTO users (user_id, name, email, created_at)
  VALUES (uuid(), 'Bob Smith', 'bob@example.com', toTimestamp(now()));
INSERT INTO users (user_id, name, email, created_at)
  VALUES (uuid(), 'Carla Diaz', 'carla@example.com', toTimestamp(now()));
INSERT INTO users (user_id, name, email, created_at)
  VALUES (uuid(), 'David Chen', 'david@example.com', toTimestamp(now()));
INSERT INTO users (user_id, name, email, created_at)
  VALUES (uuid(), 'Emma Wilson', 'emma@example.com', toTimestamp(now()));

CREATE TABLE IF NOT EXISTS events (
  event_id   uuid,
  user_id    uuid,
  event_type text,
  payload    text,
  occurred_at timestamp,
  PRIMARY KEY (event_id)
);

INSERT INTO events (event_id, user_id, event_type, payload, occurred_at)
  VALUES (uuid(), uuid(), 'login', '{"source":"web"}', toTimestamp(now()));
INSERT INTO events (event_id, user_id, event_type, payload, occurred_at)
  VALUES (uuid(), uuid(), 'purchase', '{"amount":42.50,"currency":"USD"}', toTimestamp(now()));
INSERT INTO events (event_id, user_id, event_type, payload, occurred_at)
  VALUES (uuid(), uuid(), 'logout', '{}', toTimestamp(now()));
