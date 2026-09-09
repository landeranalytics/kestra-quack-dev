-- duckdb in the browser!!!
-- https://youtu.be/L_lttD-d1wc?si=2jRy7EfDU8T3k5QL&t=1660

-- set the token
CREATE SECRET (
    TYPE quack,
    TOKEN 'abc123' -- this matches our environment variable
);

-- connect to the remote
-- port 8080 because we're using caddy
ATTACH 'quack:localhost:8080' AS quack;
ATTACH 'quack:localhost:8080' AS remote;

-- A quick test writing with one connection and reading with the other
CREATE TABLE quack.hello AS FROM VALUES ('world') v(s);
-- this won't work because the schema didn't exist before we attached
FROM remote.hello;

-- disconnect and reconnect then try again
-- this is stored and can be run as `.read retach.sql`
DETACH remote;
ATTACH 'quack:localhost:8080' AS remote;
FROM remote.hello;

-- Insert a local csv to the remote host
-- preview the file
SELECT * FROM read_csv('mtcars.csv') LIMIT 6;
CREATE TABLE quack.mtcars AS
    FROM read_csv('mtcars.csv');
-- retach remote
.read retach.sql
FROM remote.mtcars LIMIT 6;

-- truncate mtcars
-- fails because you can't run DELETE directly
DELETE 
FROM quack.mtcars
WHERE mpg < 30;
-- we use quack.query instead and it's run in quack so just `mtcars`, not `quack.mtcars`
-- this specifies compute happens on the remote
-- this is faster for large things
FROM quack.query('DELETE FROM mtcars WHERE mpg < 30');
-- check results now only has mpg >= 30
-- no need to retach because the table already existed!
FROM remote.mtcars;

-- Detach from the connections
DETACH remote;
DETACH quack;

-- you can also query without ATTACH
FROM quack_query('quack:localhost:8080', 'FROM hello');

-- run multiple hosts and connect to them from the same client to simulate multiple dbs?
