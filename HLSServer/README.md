# Simple HLS Server

This server includes
- **A distribution Endpoint** for playing the HLS playlist.
- **A WebSocket Endpoint** for uploading segmented mp4 files and playlist for streaming.


## Start the server
- `npm install` to install the dependencies
- `npm run dev:distributer` to start the distribution server listening on port `8000`.
- `npm run dev:websocket` to start the upload WebSocket server listening on port `8001`.
