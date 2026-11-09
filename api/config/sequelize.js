import { Sequelize } from 'sequelize';
import { config } from './config.js';

const sequelize = new Sequelize({
    dialect: 'sqlite',
    storage: config.db.storage,
    logging: false, // отключаем логи SQL запросов
});

export default sequelize;