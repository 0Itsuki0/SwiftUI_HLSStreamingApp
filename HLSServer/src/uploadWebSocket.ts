import { WebSocket, WebSocketServer, RawData } from "ws"
import { SEGMENTER_PORT, VIDEO_FOLDER_NAME } from "./constants"
import path from "path"
import fsAsync from "fs/promises"
import fs from "fs"

const fileBase = path.resolve(__dirname, "..", VIDEO_FOLDER_NAME)

const wss = new WebSocketServer({ port: SEGMENTER_PORT }, () => {
    console.log(`WebSocket Server is running on port ${SEGMENTER_PORT}`)
})

// For simplification, only allowing one connection at a time
let inUse = false

wss.on('connection', async (ws: WebSocket) => {
    console.log('Streamer connected')
    if (inUse) {
        ws.close(1000, "someone else is streaming. Please try again later!")
        return
    }
    inUse = true

    // clean up the destination directory
    cleanupVideoFolder()

    ws.send('Itsuki got you!')

    // data has to be sent as a json object
    // - key: file name,
    // - value: pure text string for playlist, base64 encoded for segments (mp4 and m4s)
    ws.on('message', async (data: RawData, isBinary: boolean) => {
        if (isBinary) {
            return
        }
        const text = data.toString("utf8")

        try {
            const dict: { [key: string]: string } = JSON.parse(text)
            console.log(Object.keys(dict))

            // make sure to add playlist after other files
            let playlist: [string, string] | undefined = undefined

            for (const key in dict) {
                const filePath = path.resolve(fileBase, key)
                const stringValue = dict[key]

                // playlist: pure text string
                if (key.endsWith("m3u8")) {
                    playlist = [filePath, stringValue]
                    continue
                }

                const dataBuffer = Buffer.from(`${stringValue}`, 'base64')
                await fsAsync.writeFile(filePath, dataBuffer)
            }

            if (playlist !== undefined) {
                // Only appending the new contents instead of re-writing the entire list
                //
                // This can be crucial for other clients to view the playlist in real time.
                //
                // Event Playlist entires cannot be changed once they are added.
                // If we re-write the entire playlist, there might be time gap where the playlist is entirely empty and
                // if clients request for the playlist during that gap, the playback can fail.
                await fsAsync.appendFile(playlist[0], playlist[1])
            }

        } catch (error) {
            console.log(error)
            ws.send(`Error parsing data: ${error}`)
        }
    })

    ws.on('close', () => {
        console.log('Streamer disconnected')
        inUse = false
    })

    ws.on('error', (error: Error) => {
        console.error('WebSocket error:', error)
        ws.close(1011, `${error}`)
    })

})


function cleanupVideoFolder() {
    try {
        // clean up the destination directory
        if (fs.existsSync(fileBase)) {
            fs.rmSync(fileBase, { recursive: true })
        }
        if (!fs.existsSync(fileBase)) {
            fs.mkdirSync(fileBase, { recursive: true })
        }
    } catch (error) {
        console.log(`Error cleanupVideoFolder: ${error}`)
    }

}