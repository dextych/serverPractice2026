import sequelize from "../../config/sequelize.js";
import path from 'path';
import { pathToFileURL } from "url";
import { readdir } from "fs/promises";
import { Sequelize } from "sequelize";
import { config } from "../../config/config.js";

const __dirname = config.modelsDir;
const basename = 'index.js';
const db = { Sequelize, sequelize };

async function initDb() {
    const fileNames = (await readdir(__dirname)).filter(file => file.indexOf('.') !== 0 && file !== basename && file.slice(-3) === '.js');
    
    const modelsInitFunc = (await Promise.all(
        fileNames.map(async fileName => {
            const filePath = path.resolve(__dirname, fileName);
            const fileUrl = pathToFileURL(filePath);
            
            return import(fileUrl.href);
        })
    )).map(o => o.default);

    const models = modelsInitFunc.map(modelInit => {
        return modelInit(sequelize, Sequelize.DataTypes)
    });

    models.forEach(model => {
        if(model.associate){
            model.associate(sequelize.models)
        }
        db[model.name] = model
    });

    db.sequelize = sequelize;
    db.Sequelize = Sequelize;

    await sequelize.sync({alter:true});

    return db;
}

export default await initDb();