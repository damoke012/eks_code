Idris - one thing left before QA can work on the RisingWave ETL.

The Kafka consumer group grant only ever went to dev. ix-kafka-topics-users was
deployed to the dev environment and nothing deployed it to QA, so QA's service
account can read the topics but cannot join a consumer group.

That means QA's materialized views will stay empty no matter what we deploy. It
is not a code change and the PR is already merged - it just needs that repo
deployed to the QA environment in Octopus.

Can you run that deploy and confirm it went green.

One thing to watch: the module prepends dx__ and the environment name, so the
grant renders as dx__qa_risingwave, not risingwave. If you see that in the
output it is correct.
