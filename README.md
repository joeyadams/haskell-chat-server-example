A simple chat server demonstrating asynchronous I/O (via threads) and STM.

What it does:

 * Listens for connections on port 1234.

 * When a client connects, it asks for their name.

 * If another client with the same name is already disconnected, that client
   is kicked out to make way for the new client.

 * Any lines the client sends are broadcast to all other clients.

 * Connect and disconnect notices are broadcast as well.
