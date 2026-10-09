Tim - can you check Atlas for us.

Dev is writing to rw_dev.brands and rw_dev.employees now. Both Mongo sinks
started, the compute log is clean and the connection string is wired, but nobody
has actually opened the collections and looked.

Can you confirm documents are landing in both. We can see that the sinks are
running, which is not the same thing as the data arriving.

If they are there, dev is done end to end.
