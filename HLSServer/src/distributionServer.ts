import express, { Request, Response } from "express"
import path from "path"
import { DISTRIBUTER_PORT, VIDEO_FOLDER_NAME } from "./constants"

const app = express()

// serve the playlist and the segmented files
app.get("/video/:fileName", async (req: Request, res: Response) => {
    const { fileName } = req.params

    const fullPath = path.resolve(__dirname, "..", VIDEO_FOLDER_NAME, fileName)
    console.log("requesting ", fileName)

    res.sendFile(fullPath, (err) => {
        if (err) {
            console.error(`Error serving playlist: ${err}`)
        }
    })
})

app.listen(DISTRIBUTER_PORT, () => {
    console.log(`Distribution Server started at http://localhost:${DISTRIBUTER_PORT}`)
})
