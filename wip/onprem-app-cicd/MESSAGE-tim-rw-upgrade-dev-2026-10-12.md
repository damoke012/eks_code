Tim - heads up, upgrading RisingWave on dev in a few minutes.

2.8.2 to 3.0.5. The version we were on went out of support last Saturday so
there are no more fixes or security patches for it.

Expect about five minutes where the pipeline is down - most of that is just
pulling the new image. Your sinks and the employee CDC will stop and come back
on their own.

We did prod first this morning and it went clean. I have taken a full backup of
the metadata and the entities database either way.

Nothing needed from you, I will confirm once your pipeline is back.
