import  dotenv from 'dotenv'

dotenv.config();

export const config = {
    port: process.env.PORT,

    db: {
        storage: process.env.STORAGE_DB
    },
    
    modelsDir: process.env.MODELS_DIR,
    apiKey: process.env.API_SECRET_TOKEN
}